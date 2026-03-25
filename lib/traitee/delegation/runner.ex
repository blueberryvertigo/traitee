defmodule Traitee.Delegation.Runner do
  @moduledoc """
  Parallel subagent orchestration engine.

  Spawns lightweight agent loops (not full Session.Server GenServers)
  for each delegated task. Each subagent gets a focused system prompt,
  a filtered tool set, and a simplified completion loop (max 3 tool
  iterations, no memory tiers, no security pipeline — the parent
  session already handled input security).

  IOGuard is still applied to tool execution for defense-in-depth.
  """

  alias IO.ANSI
  alias Traitee.LLM.Router, as: LLMRouter
  alias Traitee.Security.IOGuard
  alias Traitee.Tools.Registry, as: ToolRegistry

  require Logger

  @max_subagents 5
  @max_tool_depth 25
  @default_timeout 300_000
  @max_timeout 600_000

  @subagent_system_prompt """
  You are a focused subagent executing a specific delegated task.
  Complete the task thoroughly and return your results concisely.
  Do not ask clarifying questions — work with the information provided.
  Do not explain what you're about to do — just do it and report results.
  """

  @type task :: %{
          tag: String.t(),
          description: String.t(),
          tools: [String.t()]
        }

  @doc """
  Runs a list of tasks in parallel, each as an isolated subagent.

  Returns an XML-structured string with results tagged by each task's tag.

  Options:
    - `:timeout` — per-subagent timeout in ms (default: 300_000, max: 600_000)
    - `:system_prompt` — override the default subagent system prompt
    - `:session_id` — parent session ID (for audit context)
  """
  @spec run([task()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(tasks, opts \\ []) when is_list(tasks) do
    tasks = Enum.take(tasks, @max_subagents)
    timeout = min(opts[:timeout] || @default_timeout, @max_timeout)
    system_prompt = opts[:system_prompt] || @subagent_system_prompt
    session_id = opts[:session_id]

    started_at = System.monotonic_time(:millisecond)

    async_tasks =
      Enum.map(tasks, fn task ->
        Task.async(fn ->
          task_started = System.monotonic_time(:millisecond)

          result =
            run_subagent(
              task.tag,
              task.description,
              task.tools,
              system_prompt,
              session_id
            )

          duration = System.monotonic_time(:millisecond) - task_started
          {task.tag, result, duration}
        end)
      end)

    results = Task.yield_many(async_tasks, timeout)

    formatted =
      Enum.zip(async_tasks, results)
      |> Enum.map(fn {async_task, yield_result} ->
        case yield_result do
          {_, {:ok, {tag, {:ok, content, tc}, duration}}} ->
            format_subagent_result(tag, "completed", content, duration, tc)

          {_, {:ok, {tag, {:error, reason}, duration}}} ->
            format_subagent_result(tag, "error", "Error: #{inspect(reason)}", duration, 0)

          nil ->
            Task.shutdown(async_task, :brutal_kill)
            tag = find_tag_for_task(tasks, async_task, async_tasks)
            elapsed = System.monotonic_time(:millisecond) - started_at

            format_subagent_result(
              tag,
              "timeout",
              "Subagent timed out after #{elapsed}ms",
              elapsed,
              0
            )
        end
      end)

    {completed, failed} =
      Enum.reduce(formatted, {0, 0}, fn result, {c, f} ->
        if String.contains?(result, ~s(status="completed")), do: {c + 1, f}, else: {c, f + 1}
      end)

    total = length(formatted)

    xml = """
    <delegate_results count="#{total}" completed="#{completed}" failed="#{failed}">
    #{Enum.join(formatted, "\n")}
    </delegate_results>\
    """

    {:ok, String.trim(xml)}
  end

  defp run_subagent(tag, description, tool_names, system_prompt, parent_session_id) do
    status_log("▶ [#{tag}] Starting")

    tools = filter_tools(tool_names)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: description}
    ]

    subagent_loop(messages, tools, 0, 0, tag, parent_session_id)
  end

  defp subagent_loop(messages, tools, depth, tool_count, tag, session_id) do
    if depth > @max_tool_depth do
      status_log("⚠ [#{tag}] Max depth — #{tool_count} tool calls")

      content =
        Enum.find_value(Enum.reverse(messages), "Task completed (max tool depth reached).", fn
          %{role: "assistant", content: c} when is_binary(c) and c != "" -> c
          _ -> nil
        end)

      {:ok, content, tool_count}
    else
      status_log("⟳ [#{tag}] Thinking (round #{depth + 1}/#{@max_tool_depth})")

      request = %{messages: messages}

      result =
        if tools != [] do
          LLMRouter.complete_with_tools(request, tools)
        else
          LLMRouter.complete(request)
        end

      case result do
        {:ok, %{tool_calls: tool_calls, content: content}}
        when is_list(tool_calls) and tool_calls != [] ->
          new_count = tool_count + length(tool_calls)
          tool_results = execute_subagent_tools(tool_calls, tag, session_id, tool_count)

          updated =
            messages ++
              [%{role: "assistant", content: content, tool_calls: tool_calls}] ++
              tool_results

          subagent_loop(updated, tools, depth + 1, new_count, tag, session_id)

        {:ok, %{content: content}} ->
          status_log("✓ [#{tag}] Done — #{tool_count} tool calls")
          {:ok, content, tool_count}

        {:error, reason} ->
          status_err("[#{tag}] Error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp execute_subagent_tools(tool_calls, tag, session_id, offset) do
    tool_calls
    |> Enum.with_index(offset + 1)
    |> Enum.map(fn {call, idx} ->
      func = call["function"] || %{}
      tool_name = func["name"]
      args = parse_args(func["arguments"])

      status_log("⚙ [#{tag}] Tool #{idx}: #{ANSI.yellow()}#{tool_name}#{ANSI.reset()}")

      args_with_context =
        Map.put(args, "_session_id", "subagent:#{tag}:#{session_id || "unknown"}")

      result = guarded_execute(tool_name, args_with_context)

      %{
        role: "tool",
        tool_call_id: call["id"],
        name: tool_name,
        content: result
      }
    end)
  end

  defp guarded_execute(name, args) do
    case IOGuard.check_input(name, args) do
      :ok ->
        IOGuard.safe_execute(name, fn ->
          ToolRegistry.execute(name, args)
        end)
        |> format_tool_result()

      {:error, reason} ->
        "Error: #{reason}"
    end
  end

  defp format_tool_result({:ok, output}), do: output
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"

  defp filter_tools(tool_names) when is_list(tool_names) do
    all_schemas = ToolRegistry.tool_schemas()

    allowed = MapSet.new(tool_names)

    Enum.filter(all_schemas, fn schema ->
      name = get_in(schema, ["function", "name"])
      name != "delegate_task" and MapSet.member?(allowed, name)
    end)
  end

  defp filter_tools(_), do: []

  defp format_subagent_result(tag, status, content, duration_ms, tool_calls) do
    escaped_content = escape_xml(content || "")
    escaped_tag = escape_xml(tag)

    ~s[  <subagent tag="#{escaped_tag}" status="#{status}" duration_ms="#{duration_ms}" tool_calls="#{tool_calls}">\n] <>
      "    #{escaped_content}\n" <>
      "  </subagent>"
  end

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp find_tag_for_task(tasks, async_task, async_tasks) do
    idx = Enum.find_index(async_tasks, &(&1 == async_task))
    if idx, do: Enum.at(tasks, idx).tag, else: "unknown"
  end

  defp status_log(msg), do: IO.puts("#{ANSI.faint()}#{ANSI.cyan()}  #{msg}#{ANSI.reset()}")
  defp status_err(msg), do: IO.puts("#{ANSI.faint()}#{ANSI.red()}  #{msg}#{ANSI.reset()}")

  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}
end
