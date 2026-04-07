defmodule Traitee.Tools.Cognition do
  @moduledoc """
  Tool for introspecting the agent's own cognitive architecture:
  dream state, workshop projects, user model, and metacognition.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Cognition.{Dream, Interest, Metacognition, QualityControl, UserModel, Workshop}

  @impl true
  def name, do: "cognition"

  @impl true
  def description do
    "Inspect your own cognitive state: dream status, workshop projects, user interests, and self-assessment. " <>
      "Use this to check what you've been researching, what you've built, and what you know about the user."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => [
            "overview",
            "dream_status",
            "workshop_status",
            "workshop_list",
            "interests",
            "desires",
            "profile",
            "metacognition",
            "qc_status",
            "enqueue_curiosity",
            "dream_now"
          ],
          "description" =>
            "overview: full cognitive dashboard. " <>
              "dream_status: dream state details. " <>
              "workshop_status: what's being built. " <>
              "workshop_list: all projects with status. " <>
              "interests: user's top interests with scores. " <>
              "desires: user's explicit wishes. " <>
              "profile: full user profile summary. " <>
              "metacognition: self-assessment metrics. " <>
              "qc_status: quality control stats and review pipeline. " <>
              "enqueue_curiosity: queue a topic for background research. " <>
              "dream_now: trigger a dream cycle immediately."
        },
        "topic" => %{
          "type" => "string",
          "description" => "Topic for enqueue_curiosity action."
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "overview"} = args) do
    owner_id = resolve_owner(args)

    interests = format_interests(owner_id)
    desires = format_desires(owner_id)
    dream = format_dream_status()
    workshop = format_workshop_status()
    qc = format_qc_status()
    meta = format_metacognition()

    {:ok,
     """
     === Cognitive Architecture Status ===

     #{interests}

     #{desires}

     #{dream}

     #{workshop}

     #{qc}

     #{meta}
     """}
  end

  def execute(%{"action" => "dream_status"}) do
    {:ok, format_dream_status()}
  end

  def execute(%{"action" => "dream_now"}) do
    Dream.dream_now()
    {:ok, "Dream cycle triggered. Running consolidation, research, ideation, and reflection in the background."}
  end

  def execute(%{"action" => "workshop_status"}) do
    {:ok, format_workshop_status()}
  end

  def execute(%{"action" => "workshop_list"}) do
    {:ok, format_workshop_list()}
  end

  def execute(%{"action" => "interests"} = args) do
    {:ok, format_interests(resolve_owner(args))}
  end

  def execute(%{"action" => "desires"} = args) do
    {:ok, format_desires(resolve_owner(args))}
  end

  def execute(%{"action" => "profile"} = args) do
    owner_id = resolve_owner(args)
    {:ok, format_profile(owner_id)}
  end

  def execute(%{"action" => "metacognition"}) do
    {:ok, format_metacognition()}
  end

  def execute(%{"action" => "qc_status"}) do
    {:ok, format_qc_status()}
  end

  def execute(%{"action" => "enqueue_curiosity", "topic" => topic}) when is_binary(topic) do
    Dream.enqueue_curiosity(topic)
    {:ok, "Queued '#{topic}' for background research. It will be investigated during the next dream cycle."}
  end

  def execute(%{"action" => "enqueue_curiosity"}) do
    {:error, "Missing 'topic' parameter for enqueue_curiosity."}
  end

  def execute(_args) do
    {:error, "Unknown action. Use: overview, dream_status, workshop_status, workshop_list, interests, desires, profile, metacognition, enqueue_curiosity, dream_now"}
  end

  # -- Formatters --

  defp format_interests(owner_id) do
    top = UserModel.top_interests(owner_id, 10)

    if top == [] do
      "Interests: (none tracked yet — more conversations needed)"
    else
      lines =
        top
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {i, n} ->
          score = Float.round(Interest.score(i), 3)
          trend = i[:trend] || :stable
          "  #{n}. #{i.topic} — score: #{score}, depth: #{i.depth}, trend: #{trend}, seen: #{i.frequency}x"
        end)

      "Top Interests:\n#{lines}"
    end
  rescue
    _ -> "Interests: (unavailable)"
  end

  defp format_desires(owner_id) do
    desires = UserModel.desires(owner_id)

    if desires == [] do
      "Desires: (none captured yet)"
    else
      lines = Enum.map_join(desires, "\n", &"  - #{&1}")
      "User Desires:\n#{lines}"
    end
  rescue
    _ -> "Desires: (unavailable)"
  end

  defp format_profile(owner_id) do
    model = UserModel.get(owner_id)

    expertise =
      case model.expertise do
        [] -> "(none detected)"
        list -> Enum.map_join(list, ", ", fn e -> "#{e.domain}: #{e.level}" end)
      end

    projects =
      case model.active_projects do
        [] -> "(none detected)"
        list -> Enum.join(list, ", ")
      end

    style = model.style

    """
    User Profile (#{owner_id})
      Expertise: #{expertise}
      Active projects: #{projects}
      Style: formality=#{style[:formality] || "neutral"}, detail=#{style[:detail_preference] || "moderate"}
      Last updated: #{model.last_updated || "never"}

    #{format_interests(owner_id)}

    #{format_desires(owner_id)}
    """
  rescue
    _ -> "Profile: (unavailable)"
  end

  defp format_dream_status do
    status = Dream.status()

    last =
      case status.last_dream do
        nil -> "never"
        dt -> DateTime.to_string(dt)
      end

    recent =
      status.recent_dreams
      |> Enum.take(3)
      |> Enum.map_join("\n", fn d ->
        "  - #{DateTime.to_string(d.started_at)}: #{d.elapsed_seconds}s, #{d.tokens_used} tokens"
      end)

    recent_text = if recent == "", do: "  (none)", else: recent

    """
    Dream State
      Enabled: #{status.enabled}
      Last dream: #{last}
      Curiosity queue: #{status.curiosity_queue_size} topics pending
      Tokens used (last): #{status.tokens_used_last_cycle}
      Recent cycles:
    #{recent_text}
    """
  rescue
    _ -> "Dream State: (unavailable)"
  end

  defp format_workshop_status do
    status = Workshop.status()

    current =
      case status.current_project do
        nil -> "idle"
        id -> "building project ##{id}"
      end

    """
    Workshop
      Enabled: #{status.enabled}
      Status: #{current}
      Build queue: #{status.queue_size}
      Completed: #{status.completed_count}
    """
  rescue
    _ -> "Workshop: (unavailable)"
  end

  defp format_workshop_list do
    import Ecto.Query

    projects =
      Traitee.Cognition.Schema.WorkshopProject
      |> order_by([p], desc: p.inserted_at)
      |> limit(20)
      |> Traitee.Repo.all()

    if projects == [] do
      "Workshop Projects: (none yet — the Dream State generates ideas when idle)"
    else
      lines =
        Enum.map_join(projects, "\n", fn p ->
          artifacts =
            case p.artifacts do
              nil -> ""
              a when a == %{} -> ""
              a -> " | artifacts: #{inspect(a)}"
            end

          "  [#{p.id}] #{p.name} (#{p.project_type}) — #{p.status}#{artifacts}\n    #{p.description || "(no description)"}"
        end)

      "Workshop Projects (#{length(projects)}):\n#{lines}"
    end
  rescue
    _ -> "Workshop Projects: (unavailable)"
  end

  defp format_qc_status do
    qc = QualityControl.status()

    approval_rate =
      case qc.approval_rate do
        nil -> "no data"
        rate -> "#{Float.round(rate * 100, 1)}%"
      end

    """
    Quality Control
      Enabled: #{qc.enabled}
      Evaluations: #{qc.evaluations}
      Approved: #{qc.approvals}
      Rejected: #{qc.rejections}
      Approval rate: #{approval_rate}
    """
  rescue
    _ -> "Quality Control: (unavailable)"
  end

  defp format_metacognition do
    meta = Metacognition.summary()

    calibration =
      case meta.calibration_score do
        nil -> "not enough data"
        score -> "#{Float.round(score, 3)} (1.0 = perfect)"
      end

    accept_rate =
      case meta.workshop_accept_rate do
        nil -> "no data"
        rate -> "#{Float.round(rate * 100, 1)}%"
      end

    """
    Metacognition
      Calibration: #{calibration}
      Claims tracked: #{meta.total_claims} (#{meta.resolved_claims} resolved)
      Failure patterns: #{meta.failure_patterns}
      Self-improvements applied: #{meta.improvements_made}
      Workshop accept rate: #{accept_rate}
      Last check: #{meta.last_check || "never"}
    """
  rescue
    _ -> "Metacognition: (unavailable)"
  end

  defp resolve_owner(args) do
    args["_session_id"] ||
      Traitee.Config.get([:security, :owner_id]) ||
      "default"
  end
end
