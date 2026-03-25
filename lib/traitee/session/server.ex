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
  alias Traitee.Context.{Continuity, Engine}
  alias Traitee.LLM.Router, as: LLMRouter
  alias Traitee.Memory.Compactor
  alias Traitee.Memory.STM
  alias Traitee.Security.{Audit, Cognitive, IOGuard, Judge, OutputGuard, Sanitizer, ThreatTracker}
  alias Traitee.Tools.Registry, as: ToolRegistry

  require Logger

  defstruct [
    :session_id,
    :channel,
    :stm_state,
    :created_at,
    :message_count,
    channels: %{}
  ]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Traitee.Session.Registry, session_id}}
    )
  end

  @doc """
  Sends a user message through the full pipeline:
  STM -> Context Engine -> LLM -> Tool loop -> Response

  Accepts optional keyword opts:
    - reply_to: channel-specific delivery target (e.g. Telegram chat_id)
  """
  def send_message(pid, text, channel, opts \\ []) do
    GenServer.call(pid, {:message, text, channel, opts}, 120_000)
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

    stm_state = STM.push(state.stm_state, "user", sanitized_text, channel: channel)
    state = %{state | stm_state: stm_state, message_count: state.message_count + 1}

    tools = ToolRegistry.tool_schemas()

    {messages, _budget} =
      Engine.assemble(
        state.session_id,
        stm_state,
        sanitized_text,
        tools: if(tools != [], do: tools, else: nil),
        message_count: state.message_count,
        has_recent_threats: has_recent_threats
      )

    case run_completion_loop(messages, tools, state) do
      {:ok, response_text} ->
        response_text = apply_output_guard(state.session_id, response_text)

        stm_state = STM.push(state.stm_state, "assistant", response_text, channel: channel)
        state = %{state | stm_state: stm_state, message_count: state.message_count + 1}

        Continuity.persist_session(state.session_id, %{
          message_count: state.message_count
        })

        {:reply, {:ok, response_text}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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
  def handle_info({:async_tool_result, result}, state) do
    Logger.debug(
      "[#{state.session_id}] Async subagent results received (#{byte_size(result)} bytes)"
    )

    stm_state =
      STM.push(state.stm_state, "system", "[Subagent results]\n#{result}", channel: :internal)

    {:noreply, %{state | stm_state: stm_state}}
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

  defp run_completion_loop(messages, tools, %__MODULE__{} = state) do
    run_completion_loop(messages, tools, 0, state)
  end

  defp run_completion_loop(messages, tools, depth, state) do
    if depth > 50 do
      {:ok,
       "I got carried away with tools there. Could you rephrase your question? I'll try to answer directly."}
    else
      if depth > 0 do
        IO.puts("#{ANSI.faint()}#{ANSI.blue()}  ⟳ Tool round #{depth}/50#{ANSI.reset()}")
      end

      request = %{messages: messages}

      result =
        if tools != [] && tools != nil do
          LLMRouter.complete_with_tools(request, tools)
        else
          LLMRouter.complete(request)
        end

      case result do
        {:ok, %{tool_calls: tool_calls, content: content}}
        when is_list(tool_calls) and tool_calls != [] ->
          tool_results = execute_tools(tool_calls, state)

          if only_delegation?(tool_calls) do
            tags = extract_delegation_tags(tool_results)

            {:ok,
             "I've dispatched subagents to work on this#{if tags != "", do: ": #{tags}", else: ""}. " <>
               "Results will arrive shortly."}
          else
            tool_reminder =
              if Cognitive.enabled?(), do: [Cognitive.tool_reminder()], else: []

            updated_messages =
              messages ++
                [%{role: "assistant", content: content, tool_calls: tool_calls}] ++
                tool_results ++
                tool_reminder

            run_completion_loop(updated_messages, tools, depth + 1, state)
          end

        {:ok, %{content: content}} ->
          {:ok, content}

        {:error, reason} ->
          {:error, reason}
      end
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

      result = guarded_execute(name, args_with_context, state.session_id)

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
