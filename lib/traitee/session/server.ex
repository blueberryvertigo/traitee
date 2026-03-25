defmodule Traitee.Session.Server do
  @moduledoc """
  Per-session GenServer. Each user/conversation gets its own process
  with isolated state, STM buffer, and full access to the hierarchical
  memory system via the context engine.

  The session is the core unit of conversation management. It:
  - Maintains an STM buffer (ETS ring buffer)
  - Persists to SQLite for recovery
  - Uses the context engine for optimal prompt assembly
  - Handles tool execution loops
  """
  use GenServer, restart: :transient

  alias IO.ANSI
  alias Traitee.ActivityLog
  alias Traitee.Context.{Continuity, Engine}
  alias Traitee.LLM.Router, as: LLMRouter
  alias Traitee.Memory.Compactor
  alias Traitee.Memory.STM

  alias Traitee.Security.{
    Audit,
    Cognitive,
    IOGuard,
    Judge,
    OutputGuard,
    Sanitizer,
    SystemAuth,
    ThreatTracker
  }

  alias Traitee.Tools.Registry, as: ToolRegistry
  alias Traitee.Tools.TaskTracker

  require Logger

  defstruct [
    :session_id,
    :channel,
    :stm_state,
    :created_at,
    :message_count,
    channels: %{},
    delegations_expected: 0,
    delegation_results: []
  ]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Traitee.Session.Registry, session_id}}
    )
  end

  @doc """
  Sends a user message through the full pipeline (synchronous):
  STM -> Context Engine -> LLM -> Tool loop -> Response

  Accepts optional keyword opts:
    - reply_to: channel-specific delivery target (e.g. Telegram chat_id)
  """
  def send_message(pid, text, channel, opts \\ []) do
    GenServer.call(pid, {:message, text, channel, opts}, 300_000)
  end

  @doc """
  Async version of `send_message/4`. Sends progress heartbeats and the
  final response to the caller via regular messages:

    - `{:session_progress, ref, info}` — emitted each tool-loop round
    - `{:session_response, ref, {:ok, text} | {:error, reason}}` — final result

  Returns a unique `ref` the caller uses to match messages.
  """
  def send_message_streaming(pid, text, channel, opts \\ []) do
    ref = make_ref()
    GenServer.cast(pid, {:message_stream, text, channel, opts, self(), ref})
    ref
  end

  @doc """
  Returns the session's current state summary.
  """
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Returns the map of known channels with their delivery metadata.
  """
  def get_channels(pid) do
    GenServer.call(pid, :get_channels)
  end

  @doc """
  Resets the session's conversation history.
  """
  def reset(pid) do
    GenServer.call(pid, :reset)
  end

  @doc """
  Returns `{results, expected}` — accumulated delegation results and total expected count.
  Clears the results list. When all results are consumed, resets the expected counter.
  """
  def pop_delegation_results(pid) do
    GenServer.call(pid, :pop_delegation_results)
  end

  # -- Server --

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    channel = Keyword.fetch!(opts, :channel)

    stm_state = STM.init(session_id, rehydrate: true)

    Continuity.persist_session(session_id, %{channel: to_string(channel)})

    state = %__MODULE__{
      session_id: session_id,
      channel: channel,
      stm_state: stm_state,
      created_at: DateTime.utc_now(),
      message_count: STM.count(stm_state)
    }

    Logger.debug("Session started: #{session_id} (#{channel})")
    {:ok, state}
  end

  @impl true
  def handle_call({:message, text, channel, opts}, _from, state) do
    {result, state} = process_message(text, channel, opts, state, _notify = nil)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:message, text, channel}, from, state) do
    handle_call({:message, text, channel, []}, from, state)
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    summary = %{
      session_id: state.session_id,
      channel: state.channel,
      message_count: state.message_count,
      stm_size: STM.count(state.stm_state),
      stm_tokens: STM.total_tokens(state.stm_state),
      created_at: state.created_at,
      channels: state.channels
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_call(:get_channels, _from, state) do
    {:reply, state.channels, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    stm_state = STM.clear(state.stm_state)
    state = %{state | stm_state: stm_state, message_count: 0}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:pop_delegation_results, _from, state) do
    result = {state.delegation_results, state.delegations_expected}

    new_expected =
      if state.delegation_results != [] do
        max(state.delegations_expected - length(state.delegation_results), 0)
      else
        state.delegations_expected
      end

    {:reply, result, %{state | delegation_results: [], delegations_expected: new_expected}}
  end

  @impl true
  def handle_cast({:message_stream, text, channel, opts, caller, ref}, state) do
    {result, state} = process_message(text, channel, opts, state, {caller, ref})
    send(caller, {:session_response, ref, result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:delegation_dispatched, count}, state) do
    {:noreply, %{state | delegations_expected: state.delegations_expected + count}}
  end

  @impl true
  def handle_info({:async_tool_result, result}, state) do
    Logger.debug(
      "[#{state.session_id}] Async subagent results received (#{byte_size(result)} bytes)"
    )

    stm_state =
      STM.push(state.stm_state, "system", "[Subagent results]\n#{result}", channel: :internal)

    results = state.delegation_results ++ [result]
    {:noreply, %{state | stm_state: stm_state, delegation_results: results}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    remaining = STM.get_messages(state.stm_state)

    if remaining != [] do
      Compactor.compact(state.session_id, remaining)
      Compactor.flush(state.session_id)
    end

    STM.destroy(state.stm_state)
    :ok
  end

  # -- Private --

  defp process_message(text, channel, opts, state, notify) do
    state = track_channel(state, channel, opts)

    %{sanitized: sanitized_text, threats: regex_threats} = Sanitizer.sanitize(text)

    judge_threats =
      if Judge.enabled?() do
        {:ok, verdict} = Judge.evaluate(text)
        Judge.to_threats(verdict)
      else
        []
      end

    all_threats = regex_threats ++ judge_threats
    has_recent_threats = all_threats != []

    if all_threats != [] do
      ThreatTracker.record_all(state.session_id, all_threats)

      Logger.warning(
        "[#{state.session_id}] input threats: #{inspect(Enum.map(all_threats, & &1.pattern_name))}"
      )
    end

    tools = ToolRegistry.tool_schemas()

    {messages, _budget} =
      Engine.assemble(
        state.session_id,
        state.stm_state,
        sanitized_text,
        tools: if(tools != [], do: tools, else: nil),
        message_count: state.message_count,
        has_recent_threats: has_recent_threats,
        channel: channel
      )

    stm_state = STM.push(state.stm_state, "user", sanitized_text, channel: channel)
    state = %{state | stm_state: stm_state, message_count: state.message_count + 1}

    case run_completion_loop(messages, tools, state, notify) do
      {:ok, response_text} ->
        response_text = apply_output_guard(state.session_id, response_text)

        stm_state = STM.push(state.stm_state, "assistant", response_text, channel: channel)
        state = %{state | stm_state: stm_state, message_count: state.message_count + 1}

        stm_state = maybe_push_delegation_anchor(stm_state, response_text)
        state = %{state | stm_state: stm_state}

        Continuity.persist_session(state.session_id, %{
          message_count: state.message_count
        })

        {{:ok, response_text}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp apply_output_guard(session_id, text) do
    if Cognitive.enabled?() do
      case OutputGuard.check(session_id, text) do
        {:ok, text} -> text
        {:redacted, text} -> text
        {:blocked, text} -> text
      end
    else
      text
    end
  end

  defp run_completion_loop(messages, tools, %__MODULE__{} = state, notify) do
    run_completion_loop(messages, tools, 0, state, notify)
  end

  defp run_completion_loop(messages, tools, depth, state, notify) do
    if depth > 50 do
      {:ok,
       "I got carried away with tools there. Could you rephrase your question? I'll try to answer directly."}
    else
      if depth > 1 do
        IO.puts("#{ANSI.faint()}#{ANSI.blue()}  ⟳ Round #{depth}/50#{ANSI.reset()}")
      end

      notify_progress(notify, %{type: :round, depth: depth})

      request = %{messages: messages}

      llm_started = System.monotonic_time(:millisecond)

      result =
        if tools != [] && tools != nil do
          LLMRouter.complete_with_tools(request, tools)
        else
          LLMRouter.complete(request)
        end

      llm_latency = System.monotonic_time(:millisecond) - llm_started
      ActivityLog.record(state.session_id, :llm_call, %{latency_ms: llm_latency, depth: depth})

      case result do
        {:ok, %{tool_calls: tool_calls, content: content}}
        when is_list(tool_calls) and tool_calls != [] ->
          tool_names = Enum.map(tool_calls, &get_in(&1, ["function", "name"]))
          notify_progress(notify, %{type: :tools, names: tool_names})

          tool_results = execute_tools(tool_calls, state)

          if only_delegation?(tool_calls) do
            tags = extract_delegation_tags(tool_results)

            {:ok,
             "I've dispatched subagents to work on this#{if tags != "", do: ": #{tags}", else: ""}. " <>
               "Results will arrive shortly."}
          else
            tool_reminder =
              if Cognitive.enabled?(), do: [Cognitive.tool_reminder()], else: []

            task_reminder = build_task_reminder(state.session_id)

            sys_injections =
              (tool_reminder ++ task_reminder)
              |> Enum.map(&SystemAuth.tag_message(&1, state.session_id))

            updated_messages =
              messages ++
                [%{role: "assistant", content: content, tool_calls: tool_calls}] ++
                tool_results ++
                sys_injections

            run_completion_loop(updated_messages, tools, depth + 1, state, notify)
          end

        {:ok, %{content: content}} ->
          {:ok, content}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp notify_progress(nil, _info), do: :ok
  defp notify_progress({pid, ref}, info), do: send(pid, {:session_progress, ref, info})

  defp build_task_reminder(session_id) do
    case TaskTracker.compact_summary(session_id) do
      nil -> []
      summary -> [%{role: "system", content: summary}]
    end
  end

  defp execute_tools(tool_calls, state) do
    Enum.each(tool_calls, fn call ->
      name = get_in(call, ["function", "name"])

      IO.puts("#{ANSI.faint()}#{ANSI.blue()}  ⚙ #{name}#{ANSI.reset()}")
    end)

    Enum.map(tool_calls, fn call ->
      func = call["function"] || %{}
      name = func["name"]
      args = parse_args(func["arguments"])

      args_with_context =
        args
        |> Map.put("_session_id", state.session_id)
        |> then(fn a ->
          if name == "channel_send", do: Map.put(a, "_session_channels", state.channels), else: a
        end)

      started = System.monotonic_time(:millisecond)
      result = guarded_execute(name, args_with_context, state.session_id)
      duration = System.monotonic_time(:millisecond) - started

      status = if String.starts_with?(result, "Error:"), do: :error, else: :ok

      ActivityLog.record(state.session_id, :tool_call, %{
        name: name,
        status: status,
        duration_ms: duration
      })

      %{
        role: "tool",
        tool_call_id: call["id"],
        name: name,
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
        |> apply_output_guard_to_tool(name, session_id)

      {:error, reason} ->
        track_tool_denial(name, reason, session_id)
        "Error: #{reason}"
    end
  end

  defp apply_output_guard_to_tool({:ok, output}, name, session_id) do
    track_tool_output(name, output, session_id)

    case IOGuard.check_output(name, output) do
      {:clean, clean_output} -> clean_output
      {:redacted, redacted, _types} -> redacted
    end
  end

  defp apply_output_guard_to_tool({:error, reason}, name, session_id) do
    track_tool_denial(name, reason, session_id)
    "Error: #{inspect(reason)}"
  end

  defp track_tool_output(tool_name, output, session_id) when tool_name in ["bash", "file"] do
    if cogsec_output_contains_path_data?(output) do
      Audit.record(:cogsec_tool_output, %{
        tool: tool_name,
        session_id: session_id,
        output_size: String.length(output),
        decision: :allow,
        reason: "tool output tracked for cogsec"
      })
    end
  rescue
    _ -> :ok
  end

  defp track_tool_output(_tool, _output, _sid), do: :ok

  defp track_tool_denial(tool_name, reason, session_id) do
    Audit.record(:tool_denial, %{
      tool: tool_name,
      session_id: session_id,
      decision: :deny,
      reason: inspect(reason)
    })
  rescue
    _ -> :ok
  end

  defp cogsec_output_contains_path_data?(output) do
    byte_size(output) > 500 or
      Regex.match?(~r{(^|\n)(/|[A-Z]:\\)}, output)
  end

  defp track_channel(state, channel, opts) do
    reply_to = opts[:reply_to]
    sender_id = opts[:sender_id]

    if reply_to || sender_id do
      info =
        %{}
        |> then(fn m -> if reply_to, do: Map.put(m, :reply_to, reply_to), else: m end)
        |> then(fn m -> if sender_id, do: Map.put(m, :sender_id, sender_id), else: m end)
        |> Map.put(:last_seen, DateTime.utc_now())

      channels = Map.put(state.channels, channel, info)
      %{state | channels: channels}
    else
      state
    end
  end

  defp maybe_push_delegation_anchor(stm_state, response_text) do
    if String.contains?(response_text, "dispatched subagents") do
      STM.push(
        stm_state,
        "system",
        "[Delegation active] Subagents are working in the background. " <>
          "Do NOT re-dispatch the same tasks. Converse normally with the user " <>
          "until results arrive in a system message.",
        channel: :internal
      )
    else
      stm_state
    end
  end

  defp only_delegation?(tool_calls) do
    Enum.all?(tool_calls, fn call ->
      get_in(call, ["function", "name"]) == "delegate_task"
    end)
  end

  defp extract_delegation_tags(tool_results) do
    tool_results
    |> Enum.filter(&(&1[:name] == "delegate_task"))
    |> Enum.map_join(", ", fn r ->
      case Regex.run(~r/Subagents dispatched: (.+?)\./, r[:content] || "") do
        [_, tags] -> tags
        _ -> ""
      end
    end)
  end

  defp parse_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_args(args) when is_map(args), do: args
  defp parse_args(_), do: %{}
end
