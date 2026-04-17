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
  alias Traitee.ActivityLog
  alias Traitee.Delegation.Progress
  alias Traitee.LLM.Router, as: LLMRouter
  alias Traitee.Security.{IOGuard, Sanitizer, ThreatTracker, ToolOutputGuard}
  alias Traitee.Tools.Registry, as: ToolRegistry

  require Logger

  @max_subagents 5
  @max_tool_depth 25
  @default_tool_depth 10
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
          tools: [String.t()],
          max_tool_calls: non_neg_integer() | nil
        }

  @doc """
  Runs a list of tasks in parallel, each as an isolated subagent.

  Returns an XML-structured string with results tagged by each task's tag.

  Options:
    - `:timeout` — per-subagent timeout in ms (default: 300_000, max: 600_000)
    - `:system_prompt` — override the default subagent system prompt
    - `:session_id` — parent session ID (for audit context)
    - `:quiet` — suppress real-time status output (default: false)
  """
  @spec run([task()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(tasks, opts \\ []) when is_list(tasks) do
    tasks = Enum.take(tasks, @max_subagents)
    timeout = min(opts[:timeout] || @default_timeout, @max_timeout)
    system_prompt = opts[:system_prompt] || @subagent_system_prompt
    session_id = opts[:session_id]
    quiet = Keyword.get(opts, :quiet, false)

    started_at = System.monotonic_time(:millisecond)
    tags = Enum.map(tasks, & &1.tag)

    ActivityLog.record(session_id, :subagent_dispatch, %{
      tags: tags,
      count: length(tasks)
    })

    async_tasks =
      Enum.map(tasks, fn task ->
        Task.async(fn ->
          task_started = System.monotonic_time(:millisecond)
          max_calls = clamp_tool_depth(task[:max_tool_calls])

          ctx = %{
            tag: task.tag,
            session_id: session_id,
            max_calls: max_calls,
            quiet: quiet
          }

          result = run_subagent(task.description, task.tools, system_prompt, ctx)

          duration = System.monotonic_time(:millisecond) - task_started

          status =
            case result do
              {:ok, _, _} -> :completed
              {:error, _} -> :error
            end

          ActivityLog.record(session_id, :subagent_complete, %{
            tag: task.tag,
            status: status,
            duration_ms: duration
          })

          {task.tag, result, duration}
        end)
      end)

    results = Task.yield_many(async_tasks, timeout)
    Progress.clear_session(session_id)

    formatted =
      Enum.zip(async_tasks, results)
      |> Enum.map(fn {async_task, yield_result} ->
        case yield_result do
          {_, {:ok, {tag, {:ok, content, tc}, duration}}} ->
            format_subagent_result(tag, "completed", content, duration, tc)

          {_, {:ok, {tag, {:error, reason}, duration}}} ->
            format_subagent_result(tag, "error", "Error: #{inspect(reason)}", duration, 0)

          # Subagent Task crashed — `Task.yield_many` reports this as
          # `{:exit, reason}` rather than `{:ok, _}` or `nil`. Without this
          # clause the zip produced a `CaseClauseError` and the whole
          # delegation returned no result, stranding the parent session's
          # `delegations_expected` counter at +1 forever.
          {_, {:exit, reason}} ->
            tag = find_tag_for_task(tasks, async_task, async_tasks)
            elapsed = System.monotonic_time(:millisecond) - started_at
            format_subagent_result(tag, "crashed", inspect(reason), elapsed, 0)

          {_, nil} ->
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

  defp run_subagent(description, tool_names, system_prompt, ctx) do
    %{tag: tag, max_calls: max_calls, quiet: quiet, session_id: session_id} = ctx
    status_log("▶ [#{tag}] Starting (#{max_calls} tool rounds)", quiet)

    Progress.update(session_id, tag, %{
      status: "starting",
      round: 0,
      max_rounds: max_calls,
      tool_count: 0
    })

    # Inherit parent threat level. If the parent session is under attack
    # (:high or :critical), downgrade the subagent's allowed tool set and
    # depth accordingly rather than giving it a clean slate.
    parent_level = safe_parent_level(session_id)
    tools = filter_tools(tool_names, parent_level)
    effective_max = max_calls_for_level(max_calls, parent_level)

    # The task description was typed by the parent LLM from its context,
    # which may have been seeded with attacker-controlled tool output.
    # Run it through the sanitizer so blatant injection patterns are at
    # least flagged/neutralized before the subagent executes.
    sanitized_description = sanitize_description(description)

    budget_prompt =
      system_prompt <>
        "\nYou have a budget of #{effective_max} tool call rounds. " <>
        "Plan your work to finish within this limit. " <>
        "When you're running low (1-2 rounds left), wrap up and return your best results."

    messages = [
      %{role: "system", content: budget_prompt},
      %{role: "user", content: sanitized_description}
    ]

    subagent_loop(messages, tools, %{depth: 0, tool_count: 0}, %{ctx | max_calls: effective_max})
  end

  defp safe_parent_level(nil), do: :normal

  defp safe_parent_level(session_id) do
    ThreatTracker.threat_level(session_id)
  rescue
    _ -> :normal
  end

  defp sanitize_description(description) when is_binary(description) do
    case Sanitizer.sanitize(description) do
      %{sanitized: text} -> text
      _ -> description
    end
  rescue
    _ -> description
  end

  defp sanitize_description(other), do: to_string(other)

  defp max_calls_for_level(max_calls, :critical), do: min(max_calls, 3)
  defp max_calls_for_level(max_calls, :high), do: min(max_calls, 5)
  defp max_calls_for_level(max_calls, :elevated), do: min(max_calls, 10)
  defp max_calls_for_level(max_calls, _), do: max_calls

  defp subagent_loop(messages, tools, progress, ctx) do
    %{tag: tag, max_calls: max_calls, quiet: quiet, session_id: session_id} = ctx
    %{depth: depth, tool_count: tool_count} = progress

    if depth > max_calls do
      status_log("⚠ [#{tag}] Max depth — #{tool_count} tool calls", quiet)
      Progress.clear(session_id, tag)

      content =
        Enum.find_value(Enum.reverse(messages), "Task completed (max tool depth reached).", fn
          %{role: "assistant", content: c} when is_binary(c) and c != "" -> c
          _ -> nil
        end)

      {:ok, content, tool_count}
    else
      remaining = max_calls - depth
      status_log("⟳ [#{tag}] Thinking (round #{depth + 1}/#{max_calls})", quiet)

      Progress.update(session_id, tag, %{
        status: "thinking",
        round: depth + 1,
        tool_count: tool_count
      })

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

          tool_results =
            execute_subagent_tools(tool_calls, tag, session_id, tool_count, quiet)

          updated =
            messages ++
              [%{role: "assistant", content: content, tool_calls: tool_calls}] ++
              tool_results

          updated =
            if remaining <= 2 do
              budget_warn = %{
                role: "system",
                content:
                  "WARNING: You have #{remaining - 1} tool round(s) remaining. " <>
                    "Wrap up now and return your results."
              }

              updated ++ [budget_warn]
            else
              updated
            end

          subagent_loop(updated, tools, %{depth: depth + 1, tool_count: new_count}, ctx)

        {:ok, %{content: content}} ->
          status_log("✓ [#{tag}] Done — #{tool_count} tool calls", quiet)
          Progress.clear(session_id, tag)
          {:ok, content, tool_count}

        {:error, reason} ->
          status_err("[#{tag}] Error: #{inspect(reason)}", quiet)
          Progress.clear(session_id, tag)
          {:error, reason}
      end
    end
  end

  defp execute_subagent_tools(tool_calls, tag, session_id, offset, quiet) do
    tool_calls
    |> Enum.with_index(offset + 1)
    |> Enum.map(fn {call, idx} ->
      func = call["function"] || %{}
      tool_name = func["name"]
      args = parse_args(func["arguments"])

      status_log("⚙ [#{tag}] Tool #{idx}: #{ANSI.yellow()}#{tool_name}#{ANSI.reset()}", quiet)

      Progress.update(session_id, tag, %{
        status: "executing",
        tool_count: idx,
        last_tool: tool_name
      })

      # Tie subagent tools to the PARENT session_id so threat events surface
      # to the parent's ThreatTracker. This prevents the LLM from spawning a
      # subagent to launder attacks that would otherwise raise the parent's
      # threat level.
      args_with_context =
        Map.put(args, "_session_id", session_id || "subagent:#{tag}")

      result = guarded_execute(tool_name, args_with_context, session_id)

      %{
        role: "tool",
        tool_call_id: call["id"],
        name: tool_name,
        content: result
      }
    end)
  end

  defp guarded_execute(name, args, session_id) do
    case IOGuard.check_input(name, args) do
      :ok ->
        IOGuard.safe_execute(name, fn ->
          ToolRegistry.execute(name, args)
        end)
        |> apply_output_guard(name, session_id)
        |> format_tool_result()

      {:error, reason} ->
        "Error: #{reason}"
    end
  end

  # Subagents now apply the same secret-scrubbing AND prompt-injection
  # scanning as the parent session (previously: secrets-only, via IOGuard).
  defp apply_output_guard({:ok, output}, name, session_id) when is_binary(output) do
    scrubbed =
      case IOGuard.check_output(name, output) do
        {:clean, clean} -> clean
        {:redacted, redacted, _types} -> redacted
      end

    %{output: safe} =
      ToolOutputGuard.scan(scrubbed, session_id: session_id, tool: name, source: :tool)

    {:ok, safe}
  end

  defp apply_output_guard(other, _name, _session_id), do: other

  defp format_tool_result({:ok, output}), do: output
  defp format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"

  # Tools denied to subagents:
  #   • delegate_task   — recursion loop
  #   • sessions        — pivot into another session to launder actions
  #   • cron            — persistence beyond the subagent's turn
  #   • workspace_edit  — self-modification; owner-only in the parent too
  #   • skill_manage    — same
  #   • channel_send    — cross-channel exfiltration
  @subagent_denied_tools ~w(delegate_task sessions cron workspace_edit skill_manage channel_send)

  defp filter_tools(tool_names, parent_level) when is_list(tool_names) do
    all_schemas = ToolRegistry.tool_schemas()
    allowed = MapSet.new(tool_names)
    denied = denied_tools_for(parent_level)

    Enum.filter(all_schemas, fn schema ->
      name = get_in(schema, ["function", "name"])
      name not in denied and MapSet.member?(allowed, name)
    end)
  end

  defp filter_tools(_, _), do: []

  # At :high / :critical parent threat levels, additionally strip memory
  # writes and web calls so a compromised parent can't launder via a
  # subagent.
  defp denied_tools_for(:critical),
    do: @subagent_denied_tools ++ ~w(memory web_search browser bash file)

  defp denied_tools_for(:high),
    do: @subagent_denied_tools ++ ~w(memory)

  defp denied_tools_for(_), do: @subagent_denied_tools

  # Subagent content must be treated as UNTRUSTED since it was produced by a
  # separate LLM loop possibly influenced by attacker-controlled tool output.
  # In addition to XML-escaping we:
  #  • neutralize Traitee's own [SYS:xxxx] auth marker (subagents must never
  #    forge authenticated system messages),
  #  • neutralize conversation-token forms known to the Sanitizer,
  #  • length-cap the content to prevent context-budget DoS.
  @subagent_max_chars 32_000
  @subagent_max_tag_chars 128

  defp format_subagent_result(tag, status, content, duration_ms, tool_calls) do
    sanitized = neutralize_subagent_text(content || "")

    capped =
      if String.length(sanitized) > @subagent_max_chars do
        String.slice(sanitized, 0, @subagent_max_chars) <>
          "\n[TRUNCATED — subagent output too long]"
      else
        sanitized
      end

    escaped_content = escape_xml(capped)
    escaped_tag = tag |> to_string() |> String.slice(0, @subagent_max_tag_chars) |> escape_xml()

    ~s[  <subagent tag="#{escaped_tag}" status="#{status}" duration_ms="#{duration_ms}" tool_calls="#{tool_calls}">\n] <>
      "    #{escaped_content}\n" <>
      "  </subagent>"
  end

  defp neutralize_subagent_text(str) do
    %{output: neutralized} = ToolOutputGuard.scan(str, source: :subagent)
    neutralized
  end

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
    |> String.replace("\r", " ")
  end

  defp find_tag_for_task(tasks, async_task, async_tasks) do
    idx = Enum.find_index(async_tasks, &(&1 == async_task))
    if idx, do: Enum.at(tasks, idx).tag, else: "unknown"
  end

  defp clamp_tool_depth(nil), do: @default_tool_depth
  defp clamp_tool_depth(n) when is_integer(n) and n > 0, do: min(n, @max_tool_depth)
  defp clamp_tool_depth(_), do: @default_tool_depth

  defp status_log(_msg, true), do: :ok

  defp status_log(msg, _quiet),
    do: IO.puts("#{ANSI.faint()}#{ANSI.cyan()}  #{msg}#{ANSI.reset()}")

  defp status_err(_msg, true), do: :ok

  defp status_err(msg, _quiet),
    do: IO.puts("#{ANSI.faint()}#{ANSI.red()}  #{msg}#{ANSI.reset()}")

  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}
end
