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
  alias Traitee.CLI.Display
  alias Traitee.Context.{Continuity, Engine}
  alias Traitee.LLM.Router, as: LLMRouter
  alias Traitee.Memory.Compactor
  alias Traitee.Memory.STM
  alias Traitee.Session.Lifecycle

  alias Traitee.Security.{
    Audit,
    Canary,
    Cognitive,
    IOGuard,
    Judge,
    OutputGuard,
    Sanitizer,
    SystemAuth,
    ThreatTracker,
    ToolOutputGuard
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
    :last_budget,
    :compaction_state,
    :lifecycle,
    channels: %{},
    delegations_expected: 0,
    delegation_results: [],
    # Per-turn transient: hop depth for inbound inter-session messages.
    # Cleared at the end of each `process_message`.
    inter_session_depth: 0
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

  @doc "Update a session's per-session config (model, thinking, verbose, group_activation)."
  def configure(pid, key, value) do
    GenServer.call(pid, {:configure, key, value})
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
      message_count: STM.count(stm_state),
      lifecycle: Lifecycle.new(session_id, channel)
    }

    Logger.debug("Session started: #{session_id} (#{channel})")
    check_workshop_presentations(state)
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
    default_model = Traitee.Config.get([:agent, :model]) || "openai/gpt-4o"
    lc = state.lifecycle

    summary = %{
      session_id: state.session_id,
      channel: state.channel,
      message_count: state.message_count,
      stm_size: STM.count(state.stm_state),
      stm_capacity: state.stm_state.capacity,
      stm_tokens: STM.total_tokens(state.stm_state),
      created_at: state.created_at,
      channels: state.channels,
      model: lc.model_override || default_model,
      thinking_level: lc.thinking_level,
      verbose_level: lc.verbose_level,
      last_budget: state.last_budget,
      compaction_state: state.compaction_state || :idle
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_call({:configure, key, value}, _from, state) do
    lc =
      case key do
        :model -> Lifecycle.set_model(state.lifecycle, value)
        :thinking -> Lifecycle.set_thinking_level(state.lifecycle, value)
        :verbose -> Lifecycle.set_verbose(state.lifecycle, value)
        :group_activation -> Lifecycle.set_group_activation(state.lifecycle, value)
        _ -> state.lifecycle
      end

    {:reply, :ok, %{state | lifecycle: lc}}
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

    # Subagent results reach us over an unauthenticated process mailbox and
    # can carry attacker-influenced content. Neutralize conversation tokens
    # and [SYS:] markers before the content enters STM. Context.Engine will
    # additionally rewrap any role=system STM entries as untrusted user data
    # (mark_stm_origins/1), so this is defense-in-depth.
    %{output: safe_result} =
      ToolOutputGuard.scan(result,
        session_id: state.session_id,
        tool: "delegate_task",
        source: :subagent
      )

    stm_state =
      STM.push(state.stm_state, "system", "[Subagent results]\n#{safe_result}",
        channel: :internal
      )

    results = state.delegation_results ++ [safe_result]
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

    # Drop per-session state accumulated in ETS: auth nonce, canary,
    # threat tracker events, tracked tasks. Previously these entries
    # accumulated forever (and were re-used across session_id recycling).
    safe_clear(fn -> SystemAuth.clear(state.session_id) end)
    safe_clear(fn -> Canary.clear(state.session_id) end)
    safe_clear(fn -> ThreatTracker.clear(state.session_id) end)
    safe_clear(fn -> TaskTracker.clear(state.session_id) end)

    Phoenix.PubSub.broadcast(
      Traitee.PubSub,
      "session:events",
      {:session_ended, state.session_id}
    )

    :ok
  end

  defp safe_clear(fun) do
    fun.()
  rescue
    _ -> :ok
  end

  # -- Private --

  # Tools considered too powerful to expose when threat level is :high.
  # Writing to workspace/skills, sending cross-channel messages, spawning
  # subagents, scheduling cron, and pivoting to other sessions would all
  # amplify an ongoing attack.
  @high_risk_tools ~w(workspace_edit skill_manage channel_send delegate_task cron sessions memory)

  defp process_message(text, channel, opts, state, notify) do
    state = track_channel(state, channel, opts)

    # Inter-session depth is carried on the call opts by InterSession.send.
    # Default 0 so a normal inbound user message resets the chain.
    state = %{state | inter_session_depth: opts[:inter_session_depth] || 0}

    state =
      case Lifecycle.transition(state.lifecycle, :message_received) do
        {:ok, lc} -> %{state | lifecycle: lc}
        _ -> state
      end

    # Rotate the system-auth nonce per turn so a leaked nonce is useful for
    # at most the turn it leaked in. Previously the nonce was sticky for the
    # whole session.
    SystemAuth.rotate(state.session_id)

    # Defense-in-depth: strip any user-supplied [SYS:…] markers BEFORE the
    # sanitizer so an attacker cannot smuggle a forged authenticated prefix
    # into STM or the LLM's context. Zero-width characters are also
    # pre-stripped by the sanitizer now, but do it here too for clarity.
    cleaned_text =
      text
      |> SystemAuth.strip_markers()
      |> Sanitizer.strip_zero_width()

    %{sanitized: sanitized_text, threats: regex_threats} = Sanitizer.sanitize(cleaned_text)

    judge_threats =
      if Judge.enabled?() do
        case safe_judge_evaluate(cleaned_text) do
          {:ok, verdict} -> Judge.to_threats(verdict)
          _ -> []
        end
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

    threat_level = safe_threat_level(state.session_id)

    case gate_on_threat_level(threat_level, state) do
      {:refuse, refusal} ->
        Audit.record(:session_gate, %{
          session_id: state.session_id,
          decision: :deny,
          reason: "threat_level=#{threat_level}",
          tool: :pipeline
        })

        stm_state = STM.push(state.stm_state, "user", sanitized_text, channel: channel)

        stm_state =
          STM.push(stm_state, "assistant", refusal,
            channel: channel,
            meta: %{gated: true, threat_level: threat_level}
          )

        state = %{state | stm_state: stm_state, message_count: state.message_count + 2}
        {{:ok, refusal}, state}

      {:allow, tool_policy} ->
        tools = tool_policy.(ToolRegistry.tool_schemas())
        max_depth = depth_for_threat_level(threat_level)

        {messages, budget} =
          Engine.assemble(
            state.session_id,
            state.stm_state,
            sanitized_text,
            tools: if(tools != [], do: tools, else: nil),
            message_count: state.message_count,
            has_recent_threats: has_recent_threats,
            channel: channel
          )

        state = %{state | last_budget: budget}

        stm_state = STM.push(state.stm_state, "user", sanitized_text, channel: channel)
        state = %{state | stm_state: stm_state, message_count: state.message_count + 1}

        case run_completion_loop(messages, tools, 0, state, notify, max_depth) do
          {:ok, response_text} ->
            response_text = apply_output_guard(state.session_id, response_text)

            stm_state = STM.push(state.stm_state, "assistant", response_text, channel: channel)
            state = %{state | stm_state: stm_state, message_count: state.message_count + 1}

            stm_state = maybe_push_delegation_anchor(stm_state, response_text)
            state = %{state | stm_state: stm_state}

            compaction_state = detect_compaction_state(stm_state)
            state = %{state | compaction_state: compaction_state}

            # Off-load the persistence write — it does a Repo.one + Repo.update
            # round-trip and was previously inside the hot path. The caller
            # doesn't need to wait for the DB ack.
            session_id = state.session_id
            msg_count = state.message_count

            Task.start(fn ->
              try do
                Continuity.persist_session(session_id, %{message_count: msg_count})
              rescue
                e -> Logger.debug("[#{session_id}] persist_session failed: #{inspect(e)}")
              end
            end)

            {{:ok, response_text}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end
    end
  end

  # Judge contract can change; wrap the call so a future non-`{:ok, _}` return
  # doesn't crash the session with a MatchError.
  defp safe_judge_evaluate(text) do
    result = Judge.evaluate(text)

    case result do
      {:ok, verdict} -> {:ok, verdict}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    e -> {:error, e}
  end

  defp safe_threat_level(session_id) do
    ThreatTracker.threat_level(session_id)
  rescue
    _ -> :normal
  end

  # Gate the pipeline on the current threat level:
  #   :critical → refuse the turn outright with a safety message
  #   :high     → remove high-risk tools for this turn
  #   :elevated → keep all tools but reduce max tool-loop depth
  #   :normal   → proceed normally
  defp gate_on_threat_level(:critical, state) do
    Logger.error("[#{state.session_id}] Pipeline refusing message: threat_level=:critical")

    refusal =
      "I'm not able to respond to this — recent messages have triggered critical-severity " <>
        "security indicators. Please rephrase without injection-style prompts, role-override, " <>
        "or system-instruction claims."

    {:refuse, refusal}
  end

  defp gate_on_threat_level(:high, _state) do
    policy = fn tool_schemas ->
      Enum.reject(tool_schemas, fn schema ->
        name = get_in(schema, ["function", "name"])
        name in @high_risk_tools
      end)
    end

    {:allow, policy}
  end

  defp gate_on_threat_level(_other, _state) do
    {:allow, fn tool_schemas -> tool_schemas end}
  end

  defp depth_for_threat_level(:elevated), do: 10
  defp depth_for_threat_level(:high), do: 10
  defp depth_for_threat_level(_), do: 50

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

  defp run_completion_loop(messages, tools, depth, state, notify, max_depth) do
    if depth > max_depth do
      {:ok,
       "I got carried away with tools there. Could you rephrase your question? I'll try to answer directly."}
    else
      if depth > 1 do
        IO.puts("#{ANSI.faint()}#{ANSI.blue()}  ⟳ Round #{depth}/#{max_depth}#{ANSI.reset()}")
      end

      notify_progress(notify, %{type: :round, depth: depth})

      request =
        %{messages: messages}
        |> maybe_apply_model_override(state.lifecycle)

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
          # Even intermediate assistant content (the message alongside tool
          # calls) must pass OutputGuard — a jailbroken model could leak the
          # canary or echo the system prompt here without ever producing a
          # final text response.
          guarded_content = guard_intermediate_content(state.session_id, content)

          tool_names = Enum.map(tool_calls, &get_in(&1, ["function", "name"]))
          notify_progress(notify, %{type: :tools, names: tool_names})

          tool_results = execute_tools(tool_calls, state)

          if only_delegation?(tool_calls, tool_results) do
            tags = extract_delegation_tags(tool_results)

            {:ok,
             "I've dispatched subagents to work on this#{if tags != "", do: ": #{tags}", else: ""}. " <>
               "Results will arrive shortly."}
          else
            # Inject the "treat tool output as untrusted" reminder + active
            # task summary ONCE — the first time we enter a tool round in
            # this turn. Previously this was re-appended every round, so
            # after 10 rounds the prompt carried 10 copies of the same
            # reminder and 10 task snapshots.
            sys_injections =
              if depth == 0 do
                tool_reminder =
                  if Cognitive.enabled?(), do: [Cognitive.tool_reminder()], else: []

                task_reminder = build_task_reminder(state.session_id)

                (tool_reminder ++ task_reminder)
                |> Enum.map(&SystemAuth.tag_message(&1, state.session_id))
              else
                []
              end

            trimmed_results = maybe_summarize_tool_results(tool_results, state)

            updated_messages =
              messages ++
                [%{role: "assistant", content: guarded_content, tool_calls: tool_calls}] ++
                trimmed_results ++
                sys_injections

            run_completion_loop(updated_messages, tools, depth + 1, state, notify, max_depth)
          end

        {:ok, %{content: content}} ->
          {:ok, content}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp guard_intermediate_content(_session_id, nil), do: nil

  defp guard_intermediate_content(session_id, content) when is_binary(content) do
    if Cognitive.enabled?() do
      case OutputGuard.check(session_id, content) do
        {:ok, text} -> text
        {:redacted, text} -> text
        {:blocked, text} -> text
      end
    else
      content
    end
  end

  defp guard_intermediate_content(_session_id, content), do: content

  # Tool outputs can be huge (bash with `find /`, browser snapshots of long
  # pages, file tool reads). A single 100KB result re-appended to `messages`
  # on every subsequent round inflates the prompt and balloons token spend
  # quadratically. We truncate individual tool-result entries whose content
  # exceeds a per-call cap while keeping head + tail intact, which preserves
  # the most-actionable bits (initial error message / final summary).
  @tool_result_char_cap 12_000
  @tool_result_head 8_000
  @tool_result_tail 3_500

  defp maybe_summarize_tool_results(results, _state) do
    Enum.map(results, fn
      %{content: content} = msg
      when is_binary(content) and byte_size(content) > @tool_result_char_cap ->
        truncated =
          String.slice(content, 0, @tool_result_head) <>
            "\n... [#{byte_size(content) - @tool_result_head - @tool_result_tail} bytes omitted — tool output was too large to include in full] ...\n" <>
            String.slice(
              content,
              max(byte_size(content) - @tool_result_tail, 0),
              @tool_result_tail
            )

        %{msg | content: truncated}

      msg ->
        msg
    end)
  end

  defp notify_progress(nil, _info), do: :ok
  defp notify_progress({pid, ref}, info), do: send(pid, {:session_progress, ref, info})

  defp build_task_reminder(session_id) do
    case TaskTracker.compact_summary(session_id) do
      nil -> []
      summary -> [%{role: "system", content: summary}]
    end
  end

  # Execute a batch of tool_calls from a single LLM round.
  #
  # Tool calls in the same round are typically independent (the LLM emits 3-5
  # parallel reads for research, filesystem inspection, etc.) so running them
  # sequentially was a major latency tax — the round took as long as the sum
  # of all calls instead of the slowest one.
  #
  # We use `Task.async_stream` with `ordered: true` so results are paired
  # back to the original tool_call ordering, which is what the LLM's
  # tool_call_id → tool message mapping requires.
  @tool_parallelism 5
  @tool_timeout_ms 300_000

  defp execute_tools(tool_calls, state) do
    # Compute session/ownership context ONCE per round — it's identical for
    # every tool in the same round.
    {sender_id, channel_type} = most_recent_sender(state.channels)

    is_owner =
      if sender_id && channel_type do
        Traitee.Config.sender_is_owner?(sender_id, channel_type)
      else
        false
      end

    # Inter-session hop depth — tracked so `sessions.send` can't spawn an
    # unbounded ping-pong between sessions.
    context_base = %{
      "_session_id" => state.session_id,
      "_session_sender_id" => sender_id,
      "_session_channel_type" => channel_type,
      "_session_is_owner" => is_owner,
      "_inter_session_depth" => state.inter_session_depth || 0
    }

    tool_calls
    |> Task.async_stream(
      fn call -> run_one_tool(call, state, context_base) end,
      max_concurrency: @tool_parallelism,
      ordered: true,
      timeout: @tool_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(tool_calls)
    |> Enum.map(fn
      {{:ok, result_msg}, _call} ->
        result_msg

      {{:exit, reason}, call} ->
        %{
          role: "tool",
          tool_call_id: call["id"],
          name: (call["function"] || %{})["name"],
          content: "Error: tool execution failed — #{inspect(reason)}"
        }
    end)
  end

  defp run_one_tool(call, state, context_base) do
    func = call["function"] || %{}
    name = func["name"]
    args = parse_args(func["arguments"])

    label = Display.tool_summary(name, args)
    IO.puts("#{ANSI.faint()}#{ANSI.blue()}  ⚙ #{label}#{ANSI.reset()}")

    args_with_context =
      args
      |> Map.merge(context_base)
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

    scrubbed =
      case IOGuard.check_output(name, output) do
        {:clean, clean_output} -> clean_output
        {:redacted, redacted, _types} -> redacted
      end

    # Tool output is the #1 prompt-injection vector. In addition to secret
    # scrubbing by IOGuard, run the ToolOutputGuard which neutralizes
    # conversation tokens, strips Traitee's own [SYS:…] marker, and charges
    # any injection-pattern hits to the session's ThreatTracker.
    %{output: safe} =
      ToolOutputGuard.scan(scrubbed, session_id: session_id, tool: name, source: :tool)

    safe
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

  # Returns {sender_id, channel_type} for the most recently-seen channel
  # on this session, or {nil, nil} if the session has never received an
  # identified message (e.g. it was spawned by a subagent or cron job).
  defp most_recent_sender(channels) when is_map(channels) and map_size(channels) > 0 do
    channels
    |> Enum.sort_by(fn {_ch, info} -> info[:last_seen] end, {:desc, DateTime})
    |> Enum.find_value({nil, nil}, fn {ch, info} ->
      case info[:sender_id] do
        nil -> nil
        "" -> nil
        sid -> {to_string(sid), ch}
      end
    end)
  end

  defp most_recent_sender(_), do: {nil, nil}

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

  defp only_delegation?(tool_calls, tool_results) do
    all_delegate? =
      Enum.all?(tool_calls, fn call ->
        get_in(call, ["function", "name"]) == "delegate_task"
      end)

    actually_dispatched? =
      Enum.any?(tool_results, fn r ->
        String.contains?(r[:content] || "", "Subagents dispatched")
      end)

    all_delegate? and actually_dispatched?
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

  defp detect_compaction_state(stm_state) do
    count = STM.count(stm_state)
    cap = stm_state.capacity
    fill = if cap > 0, do: count / cap, else: 0.0

    cond do
      fill >= 0.90 -> :critical
      fill >= 0.75 -> :near
      true -> :idle
    end
  end

  defp check_workshop_presentations(state) do
    Task.start(fn ->
      owner_id = Traitee.Config.get([:security, :owner_id])

      if owner_id do
        presentations = Traitee.Cognition.Workshop.pending_presentations(owner_id)

        Enum.each(presentations, fn project ->
          Traitee.Cognition.Workshop.mark_presented(project.id)

          STM.push(
            state.stm_state,
            "system",
            "[Workshop] While you were away, I built '#{project.name}': #{project.description}. " <>
              "Type: #{project.project_type}. Artifacts: #{inspect(project.artifacts)}. " <>
              "Mention this to the user when appropriate.",
            channel: :internal
          )
        end)
      end
    end)
  rescue
    _ -> :ok
  end

  defp maybe_apply_model_override(request, %Lifecycle{model_override: nil}), do: request

  defp maybe_apply_model_override(request, %Lifecycle{model_override: model}) do
    Map.put(request, :model_override, model)
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
