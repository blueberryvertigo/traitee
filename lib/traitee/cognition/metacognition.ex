defmodule Traitee.Cognition.Metacognition do
  @moduledoc """
  Self-monitoring and self-improvement agent. Tracks performance signals,
  calibrates confidence, detects failure patterns, and triggers self-modification
  via workspace_edit and skill_manage.
  """
  use GenServer

  alias Traitee.ActivityLog
  alias Traitee.Cognition.Workshop
  alias Traitee.LLM.Router
  alias Traitee.Memory.LTM
  alias Traitee.Workspace

  require Logger

  @check_interval_ms 30 * 60_000
  @max_tracked_sessions 200
  @max_workshop_feedback 500

  defstruct calibration: %{},
            failure_patterns: [],
            improvement_history: [],
            workshop_feedback: %{},
            last_check: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a confidence-tagged claim for calibration tracking."
  def record_claim(session_id, claim, confidence) do
    GenServer.cast(__MODULE__, {:claim, session_id, claim, confidence, DateTime.utc_now()})
  end

  @doc "Record the outcome of a previous claim (confirmed/refuted)."
  def record_outcome(session_id, claim, outcome) when outcome in [:confirmed, :refuted] do
    GenServer.cast(__MODULE__, {:outcome, session_id, claim, outcome})
  end

  @doc "Record user feedback on a workshop project."
  def record_workshop_feedback(project_id, feedback)
      when feedback in [:accept, :reject, :ignore] do
    GenServer.cast(__MODULE__, {:workshop_feedback, project_id, feedback})
    Workshop.user_feedback(project_id, feedback)
  end

  @doc "Get the current metacognition summary."
  def summary do
    GenServer.call(__MODULE__, :summary)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Traitee.PubSub, "workshop:events")
    Phoenix.PubSub.subscribe(Traitee.PubSub, "dream:events")
    schedule_check()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:claim, session_id, claim, confidence, timestamp}, state) do
    entry = %{
      session_id: session_id,
      claim: claim,
      confidence: confidence,
      timestamp: timestamp,
      outcome: nil
    }

    claims = Map.get(state.calibration, session_id, [])
    updated = [entry | Enum.take(claims, 99)]

    # Cap the number of DISTINCT sessions tracked; oldest-by-insertion order
    # get dropped. Previously entries for dead sessions accumulated forever.
    calibration =
      state.calibration
      |> Map.put(session_id, updated)
      |> cap_map_size(@max_tracked_sessions)

    {:noreply, %{state | calibration: calibration}}
  end

  @impl true
  def handle_cast({:outcome, session_id, claim, outcome}, state) do
    claims = Map.get(state.calibration, session_id, [])

    updated =
      Enum.map(claims, fn c ->
        if c.claim == claim and c.outcome == nil do
          %{c | outcome: outcome}
        else
          c
        end
      end)

    calibration = Map.put(state.calibration, session_id, updated)
    {:noreply, %{state | calibration: calibration}}
  end

  @impl true
  def handle_cast({:workshop_feedback, project_id, feedback}, state) do
    ws_feedback =
      state.workshop_feedback
      |> Map.put(project_id, feedback)
      |> cap_map_size(@max_workshop_feedback)

    {:noreply, %{state | workshop_feedback: ws_feedback}}
  end

  # Drop-oldest eviction when a map grows past its cap. We don't have an
  # explicit insertion order; map iteration order is stable per-key but not
  # time-ordered — as a rough proxy we just drop whichever keys the enum
  # visits last over the cap. Good enough: per-session lists already cap at
  # 99 entries so each dropped session is ≤99 items.
  defp cap_map_size(map, cap) when map_size(map) > cap do
    drop_count = map_size(map) - cap
    keys_to_drop = map |> Map.keys() |> Enum.take(drop_count)
    Map.drop(map, keys_to_drop)
  end

  defp cap_map_size(map, _cap), do: map

  @impl true
  def handle_info(:check, state) do
    state = run_metacognition_check(state)
    schedule_check()
    {:noreply, state}
  end

  @impl true
  def handle_info({:workshop, :build_complete, meta}, state) do
    Logger.debug("[Metacognition] Workshop build complete: #{inspect(meta)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:dream, :dream_completed, meta}, state) do
    Logger.debug("[Metacognition] Dream cycle complete: #{inspect(meta)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:summary, _from, state) do
    calibration_score = compute_calibration_score(state.calibration)

    summary = %{
      calibration_score: calibration_score,
      total_claims: count_claims(state.calibration),
      resolved_claims: count_resolved_claims(state.calibration),
      failure_patterns: length(state.failure_patterns),
      improvements_made: length(state.improvement_history),
      workshop_accept_rate: compute_accept_rate(state.workshop_feedback),
      last_check: state.last_check
    }

    {:reply, summary, state}
  end

  # -- Metacognition Check --

  defp run_metacognition_check(state) do
    Logger.debug("[Metacognition] Running periodic check")

    state
    |> detect_failure_patterns()
    |> analyze_workshop_feedback()
    |> maybe_self_improve()
    |> Map.put(:last_check, DateTime.utc_now())
  rescue
    e ->
      Logger.warning("[Metacognition] Check failed: #{inspect(e)}")
      state
  end

  defp detect_failure_patterns(state) do
    recent_failures =
      try do
        Traitee.Session.list_active()
        |> Enum.flat_map(fn {sid, _} -> ActivityLog.recent(sid, 50) end)
        |> Enum.filter(fn entry ->
          entry.type == :tool_call and entry[:status] == :error
        end)
        |> Enum.group_by(fn entry -> entry[:name] end)
        |> Enum.filter(fn {_name, entries} -> length(entries) >= 3 end)
        |> Enum.map(fn {name, entries} ->
          %{tool: name, failure_count: length(entries), pattern: "recurring_tool_failure"}
        end)
      rescue
        _ -> []
      end

    %{state | failure_patterns: recent_failures}
  end

  defp analyze_workshop_feedback(state) do
    feedback = state.workshop_feedback

    reject_count = Enum.count(feedback, fn {_, v} -> v == :reject end)
    total = map_size(feedback)

    if total > 3 and reject_count / total > 0.5 do
      Logger.info(
        "[Metacognition] High project rejection rate (#{reject_count}/#{total}). Adjusting ideation."
      )

      owner_id = Traitee.Config.get([:security, :owner_id])

      if owner_id do
        {:ok, entity} = LTM.upsert_entity("workshop_feedback", "metacognition")

        LTM.add_fact(
          entity.id,
          "User rejected #{reject_count}/#{total} workshop projects. Build more practical, less speculative projects.",
          "self_improvement"
        )
      end
    end

    state
  rescue
    _ -> state
  end

  defp maybe_self_improve(state) do
    if state.failure_patterns != [] do
      patterns_text =
        state.failure_patterns
        |> Enum.map_join("\n", fn p -> "- Tool '#{p.tool}' failed #{p.failure_count} times" end)

      prompt = """
      The AI assistant has detected these recurring failure patterns:

      #{patterns_text}

      Suggest a specific, actionable improvement to the assistant's behavior.
      Keep it to one concrete suggestion that could be added to the system prompt.
      Return JSON: {"suggestion": "the improvement text", "target": "soul|skill"}
      """

      case Router.complete(%{
             messages: [%{role: "user", content: prompt}],
             system: "You are a self-improvement analyst. Return valid JSON only."
           }) do
        {:ok, %{content: content}} ->
          apply_improvement(content, state)

        _ ->
          state
      end
    else
      state
    end
  rescue
    _ -> state
  end

  defp apply_improvement(content, state) do
    case parse_json(content) do
      {:ok, %{"suggestion" => suggestion, "target" => "soul"}} ->
        # Workspace.append_to_file/2 is guarded by `key in [:soul, :agents, :tools]`.
        # Previously this passed the string "SOUL" which silently raised a
        # FunctionClauseError (caught by the outer rescue) — the entire
        # SOUL self-improvement feature was inoperative.
        case Workspace.append_to_file(:soul, "\n\n## Self-Improvement Note\n#{suggestion}") do
          :ok ->
            entry = %{type: :soul_update, suggestion: suggestion, applied_at: DateTime.utc_now()}
            Logger.info("[Metacognition] Applied self-improvement to SOUL.md")
            %{state | improvement_history: [entry | Enum.take(state.improvement_history, 49)]}

          _ ->
            state
        end

      {:ok, %{"suggestion" => suggestion}} ->
        {:ok, entity} = LTM.upsert_entity("self_improvement", "metacognition")
        # Store at reduced confidence to match compactor-style provenance —
        # these are self-generated, not user-grounded, and should rank below
        # real user memories in retrieval.
        LTM.add_fact(entity.id, suggestion, "improvement_suggestion", nil,
          confidence: 0.4,
          metadata: %{"source" => "metacognition"}
        )

        entry = %{type: :ltm_note, suggestion: suggestion, applied_at: DateTime.utc_now()}
        %{state | improvement_history: [entry | Enum.take(state.improvement_history, 49)]}

      _ ->
        state
    end
  rescue
    _ -> state
  end

  # -- Calibration --

  defp compute_calibration_score(calibration) do
    all_resolved =
      calibration
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1.outcome != nil))

    if length(all_resolved) < 5 do
      nil
    else
      buckets =
        all_resolved
        |> Enum.group_by(fn c -> Float.round(c.confidence, 1) end)
        |> Enum.map(fn {conf, claims} ->
          actual = Enum.count(claims, &(&1.outcome == :confirmed)) / length(claims)
          abs(conf - actual)
        end)

      1.0 - Enum.sum(buckets) / max(length(buckets), 1)
    end
  rescue
    _ -> nil
  end

  defp count_claims(calibration) do
    calibration |> Map.values() |> List.flatten() |> length()
  end

  defp count_resolved_claims(calibration) do
    calibration
    |> Map.values()
    |> List.flatten()
    |> Enum.count(&(&1.outcome != nil))
  end

  defp compute_accept_rate(feedback) do
    total = map_size(feedback)

    if total == 0 do
      nil
    else
      accepts = Enum.count(feedback, fn {_, v} -> v == :accept end)
      Float.round(accepts / total, 2)
    end
  end

  # -- Helpers --

  defp parse_json(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> Jason.decode()
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end
end
