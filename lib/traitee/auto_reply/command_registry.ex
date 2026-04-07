defmodule Traitee.AutoReply.CommandRegistry do
  @moduledoc "Command registry with argument parsing and authorization."

  alias Traitee.Cron.Scheduler
  alias Traitee.LLM.Router
  alias Traitee.Memory.{Compactor, LTM, Vector}
  alias Traitee.Routing.AgentRouter
  alias Traitee.Security.Pairing
  alias Traitee.Session

  @type command_opts :: %{
          description: String.t(),
          args_schema: list(),
          requires_owner: boolean(),
          cli_only: boolean(),
          hidden: boolean()
        }

  @builtin_commands %{
    "new" => %{
      handler: :cmd_new,
      description: "Reset conversation",
      requires_owner: false,
      hidden: false
    },
    "reset" => %{
      handler: :cmd_new,
      description: "Reset conversation (alias)",
      requires_owner: false,
      hidden: true
    },
    "model" => %{
      handler: :cmd_model,
      description: "Switch model — /model <name>",
      requires_owner: false,
      hidden: false
    },
    "think" => %{
      handler: :cmd_think,
      description: "Set thinking level — /think off|low|medium|high",
      requires_owner: false,
      hidden: false
    },
    "verbose" => %{
      handler: :cmd_verbose,
      description: "Toggle verbose — /verbose on|off",
      requires_owner: false,
      hidden: false
    },
    "usage" => %{
      handler: :cmd_usage,
      description: "Token usage — /usage [off|tokens|full]",
      requires_owner: false,
      hidden: false
    },
    "status" => %{
      handler: :cmd_status,
      description: "Session + system status",
      requires_owner: false,
      hidden: false
    },
    "memory" => %{
      handler: :cmd_memory,
      description: "Memory ops — /memory [stats|search <q>|entities]",
      requires_owner: false,
      hidden: false
    },
    "compact" => %{
      handler: :cmd_compact,
      description: "Force compaction",
      requires_owner: false,
      hidden: false
    },
    "context" => %{
      handler: :cmd_context,
      description: "Show context window status bar",
      requires_owner: false,
      hidden: false
    },
    "help" => %{
      handler: :cmd_help,
      description: "List commands",
      requires_owner: false,
      hidden: false
    },
    "doctor" => %{
      handler: :cmd_doctor,
      description: "Run diagnostics",
      requires_owner: true,
      cli_only: true,
      hidden: false
    },
    "cron" => %{
      handler: :cmd_cron,
      description: "Cron management — /cron [list|add|remove]",
      requires_owner: true,
      hidden: false
    },
    "pairing" => %{
      handler: :cmd_pairing,
      description: "Pairing — /pairing [approve|revoke|list]",
      requires_owner: true,
      hidden: false
    },
    "threats" => %{
      handler: :cmd_threats,
      description: "Show threat level and security state",
      requires_owner: true,
      cli_only: true,
      hidden: false
    },
    "dream" => %{
      handler: :cmd_dream,
      description: "Dream state — /dream [status|now]",
      requires_owner: true,
      hidden: false
    },
    "workshop" => %{
      handler: :cmd_workshop,
      description: "Workshop — /workshop [status|list|build <id>]",
      requires_owner: true,
      hidden: false
    },
    "cognition" => %{
      handler: :cmd_cognition,
      description: "Cognition status — interests, dream, workshop, metacognition",
      requires_owner: true,
      hidden: false
    },
    "qc" => %{
      handler: :cmd_qc,
      description: "Quality control — /qc [status|review <project_id>]",
      requires_owner: true,
      hidden: false
    }
  }

  @spec execute(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def execute(command_string, context) do
    case parse_command(command_string) do
      {name, args} ->
        case Map.get(@builtin_commands, name) do
          nil -> {:error, :unknown_command}
          cmd -> dispatch(cmd, args, context)
        end
    end
  end

  @spec parse_command(String.t()) :: {String.t(), [String.t()]}
  def parse_command("/" <> rest) do
    [name | args] = String.split(rest, ~r/\s+/, trim: true)
    {String.downcase(name), args}
  end

  def parse_command(text), do: parse_command("/" <> text)

  @spec help_text() :: String.t()
  def help_text do
    @builtin_commands
    |> Enum.reject(fn {_, cmd} -> cmd.hidden end)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("\n", fn {name, cmd} -> "/#{name} — #{cmd.description}" end)
    |> then(&("Commands:\n" <> &1))
  end

  # -- Dispatch --

  defp dispatch(%{cli_only: true}, _args, %{inbound: %{channel_type: ch}}) when ch != :cli do
    {:error, :cli_only}
  end

  defp dispatch(%{requires_owner: true} = cmd, args, %{inbound: inbound} = ctx) do
    if Traitee.Config.sender_is_owner?(inbound.sender_id, inbound.channel_type) do
      apply(__MODULE__, cmd.handler, [args, ctx])
    else
      {:error, :unauthorized}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp dispatch(%{handler: handler}, args, context) do
    apply(__MODULE__, handler, [args, context])
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Command Handlers --

  def cmd_new(_args, %{inbound: inbound}) do
    session_id = build_session_id(inbound)
    Session.terminate(session_id)
    {:ok, "Session reset. Starting fresh."}
  end

  def cmd_model([], _ctx), do: {:ok, "Current model: #{Traitee.Config.get([:agent, :model])}"}

  def cmd_model([name | _], %{inbound: inbound}) do
    configure_session(inbound, :model, name)
    {:ok, "Model set to: #{name}"}
  end

  def cmd_think([], _ctx), do: {:ok, "Usage: /think off|low|medium|high"}

  def cmd_think([level | _], %{inbound: inbound}) when level in ~w(off minimal low medium high) do
    configure_session(inbound, :thinking, String.to_existing_atom(level))
    {:ok, "Thinking level set to: #{level}"}
  end

  def cmd_think(_, _ctx), do: {:ok, "Valid levels: off, minimal, low, medium, high"}

  def cmd_verbose([], _ctx), do: {:ok, "Usage: /verbose on|off"}

  def cmd_verbose([mode | _], %{inbound: inbound}) when mode in ~w(on off) do
    configure_session(inbound, :verbose, String.to_existing_atom(mode))
    {:ok, "Verbose mode: #{mode}"}
  end

  def cmd_verbose(_, _ctx), do: {:ok, "Usage: /verbose on|off"}

  def cmd_usage(_args, _ctx) do
    stats = Router.usage_stats()

    text =
      "Requests: #{stats.requests}\n" <>
        "Tokens in: #{stats.tokens_in}\n" <>
        "Tokens out: #{stats.tokens_out}\n" <>
        "Est. cost: $#{Float.round(stats.cost, 4)}"

    {:ok, text}
  end

  def cmd_status(_args, _ctx) do
    info = Router.model_info()
    stats = Router.usage_stats()
    sessions = Session.list_active() |> length()

    text =
      "Model: #{info.provider}/#{info.id}\n" <>
        "Active sessions: #{sessions}\n" <>
        "Requests: #{stats.requests} | Tokens: #{stats.tokens_in + stats.tokens_out}"

    {:ok, text}
  end

  def cmd_memory(["search" | query_parts], _ctx) when query_parts != [] do
    query = Enum.join(query_parts, " ")
    {:ok, "Searching memory for: #{query}"}
  end

  def cmd_memory(["entities" | _], _ctx) do
    ltm = LTM.stats()
    {:ok, "Entities: #{ltm.entities}, Relations: #{ltm.relations}"}
  end

  def cmd_memory(_args, _ctx) do
    ltm = LTM.stats()
    vectors = Vector.count()

    text =
      "Entities: #{ltm.entities}\nRelations: #{ltm.relations}\n" <>
        "Facts: #{ltm.facts}\nVectors: #{vectors}"

    {:ok, text}
  end

  def cmd_compact(_args, %{inbound: inbound}) do
    session_id = build_session_id(inbound)
    Compactor.flush(session_id)
    {:ok, "Compaction triggered."}
  end

  def cmd_context(_args, %{session_pid: pid}) do
    alias Traitee.Context.StatusBar

    state = Traitee.Session.Server.get_state(pid)

    status_data = StatusBar.from_session(%{
      model: state.model,
      budget: state.last_budget,
      stm_count: state.stm_size,
      stm_capacity: state.stm_capacity,
      session_start: state.created_at,
      compaction_state: state.compaction_state
    })

    bar = StatusBar.render(status_data)

    detail =
      if state.last_budget do
        budget = state.last_budget
        "\n" <> Traitee.Context.Budget.budget_summary(budget)
      else
        "\n(No context assembly yet — send a message first)"
      end

    {:ok, bar <> detail}
  end

  def cmd_context(_args, _ctx), do: {:ok, "No active session."}

  def cmd_help(_args, _ctx), do: {:ok, help_text()}

  def cmd_doctor(_args, _ctx) do
    report = Traitee.Doctor.run_all() |> Traitee.Doctor.format_report()
    {:ok, report}
  end

  def cmd_cron(["list" | _], _ctx) do
    jobs = Scheduler.list_jobs()

    if jobs == [] do
      {:ok, "No scheduled jobs."}
    else
      lines =
        Enum.map(jobs, fn job ->
          status = if job.enabled, do: "active", else: "paused"
          next = if job.next_run_at, do: DateTime.to_string(job.next_run_at), else: "—"

          "  #{job.name} [#{job.job_type}] #{status}\n" <>
            "    Schedule: #{job.schedule}\n" <>
            "    Next: #{next} | Runs: #{job.run_count}"
        end)

      {:ok, "Scheduled Jobs\n" <> Enum.join(lines, "\n")}
    end
  end

  def cmd_cron(["add", name, schedule | message_parts], _ctx) when message_parts != [] do
    message = Enum.join(message_parts, " ")
    job_type = cron_detect_type(schedule)

    attrs = %{
      name: name,
      job_type: job_type,
      schedule: schedule,
      payload: %{"message" => message},
      enabled: true
    }

    case Scheduler.add_job(attrs) do
      {:ok, job} ->
        {:ok, "Job '#{job.name}' added (#{job_type}, next: #{job.next_run_at || "now"})"}

      {:error, changeset} ->
        {:ok, "Error: #{inspect(changeset.errors)}"}
    end
  end

  def cmd_cron(["remove", name | _], _ctx) do
    case Scheduler.remove_job(name) do
      :ok -> {:ok, "Job '#{name}' removed."}
      {:error, :not_found} -> {:ok, "Job '#{name}' not found."}
    end
  end

  def cmd_cron(["run", name | _], _ctx) do
    case Scheduler.run_job(name) do
      :ok -> {:ok, "Job '#{name}' executed."}
      {:error, :not_found} -> {:ok, "Job '#{name}' not found."}
    end
  end

  def cmd_cron(["pause", name | _], _ctx) do
    case Scheduler.pause_job(name) do
      :ok -> {:ok, "Job '#{name}' paused."}
      {:error, :not_found} -> {:ok, "Job '#{name}' not found."}
    end
  end

  def cmd_cron(["resume", name | _], _ctx) do
    case Scheduler.resume_job(name) do
      :ok -> {:ok, "Job '#{name}' resumed."}
      {:error, :not_found} -> {:ok, "Job '#{name}' not found."}
    end
  end

  def cmd_cron(_, _ctx) do
    {:ok,
     "Usage: /cron [list|add <name> <schedule> <msg>|remove <name>|run <name>|pause <name>|resume <name>]"}
  end

  defp cron_detect_type(schedule) do
    cond do
      Regex.match?(~r/^\d{4}-/, schedule) -> "at"
      Regex.match?(~r/^\d+$/, schedule) -> "every"
      true -> "cron"
    end
  end

  def cmd_pairing(["approve", code | _], _ctx) do
    case Pairing.approve(code) do
      {:ok, key} -> {:ok, "Approved: #{key}"}
      {:error, :not_found} -> {:ok, "No pending pairing found for code: #{code}"}
    end
  end

  def cmd_pairing(["revoke", channel, sender_id | _], _ctx) do
    key = "#{channel}:#{sender_id}"
    Pairing.revoke(key)
    {:ok, "Revoked: #{key}"}
  end

  def cmd_pairing(["list" | _], _ctx) do
    approved = Pairing.list_approved()
    pending = Pairing.list_pending()

    approved_text =
      if approved == [],
        do: "  (none)",
        else:
          Enum.map_join(approved, "\n", fn key ->
            case String.split(key, ":", parts: 2) do
              [ch, id] -> "  #{id} [#{ch}]"
              _ -> "  #{key}"
            end
          end)

    pending_text =
      if pending == [],
        do: "  (none)",
        else:
          Enum.map_join(pending, "\n", fn p ->
            "  #{p.sender_id} [#{p.channel}] code: #{p.code}"
          end)

    {:ok,
     "Approved (#{length(approved)}):\n#{approved_text}\nPending (#{length(pending)}):\n#{pending_text}"}
  end

  def cmd_pairing(_, _ctx),
    do: {:ok, "Usage: /pairing [list|approve <code>|revoke <channel> <id>]"}

  def cmd_threats(_args, %{inbound: inbound}) do
    alias Traitee.Security.ThreatTracker

    session_id = build_session_id(inbound)
    {:ok, ThreatTracker.summary(session_id)}
  end

  # -- Cognition Commands --

  def cmd_dream(["now" | _], _ctx) do
    Traitee.Cognition.Dream.dream_now()
    {:ok, "Dream cycle triggered. Running in background."}
  end

  def cmd_dream(_args, _ctx) do
    status = Traitee.Cognition.Dream.status()

    last =
      case status.last_dream do
        nil -> "never"
        dt -> "#{DateTime.to_string(dt)}"
      end

    text =
      "Dream State\n" <>
        "  Enabled: #{status.enabled}\n" <>
        "  Last dream: #{last}\n" <>
        "  Curiosity queue: #{status.curiosity_queue_size} topics\n" <>
        "  Tokens used (last cycle): #{status.tokens_used_last_cycle}"

    {:ok, text}
  rescue
    _ -> {:ok, "Dream state not available (cognition may be disabled)."}
  end

  def cmd_workshop(["list" | _], _ctx) do
    import Ecto.Query

    projects =
      Traitee.Cognition.Schema.WorkshopProject
      |> order_by([p], desc: p.inserted_at)
      |> limit(20)
      |> Traitee.Repo.all()

    if projects == [] do
      {:ok, "No workshop projects yet. The Dream State generates ideas when idle."}
    else
      lines =
        Enum.map(projects, fn p ->
          "  #{p.name} [#{p.project_type}] #{p.status}\n    #{p.description || "(no description)"}"
        end)

      {:ok, "Workshop Projects (#{length(projects)})\n" <> Enum.join(lines, "\n")}
    end
  rescue
    _ -> {:ok, "Workshop not available."}
  end

  def cmd_workshop(["build", id | _], _ctx) do
    case Integer.parse(id) do
      {project_id, _} ->
        Traitee.Cognition.Workshop.enqueue(project_id)
        {:ok, "Project #{project_id} queued for building."}

      :error ->
        {:ok, "Usage: /workshop build <project_id>"}
    end
  end

  def cmd_workshop(_args, _ctx) do
    status = Traitee.Cognition.Workshop.status()

    current =
      case status.current_project do
        nil -> "none"
        id -> "project ##{id}"
      end

    text =
      "Workshop\n" <>
        "  Enabled: #{status.enabled}\n" <>
        "  Currently building: #{current}\n" <>
        "  Queue: #{status.queue_size}\n" <>
        "  Completed: #{status.completed_count}"

    {:ok, text}
  rescue
    _ -> {:ok, "Workshop not available (cognition may be disabled)."}
  end

  def cmd_cognition(_args, %{inbound: inbound}) do
    owner_id =
      Traitee.Config.get([:security, :owner_id]) || to_string(inbound.sender_id)

    interests =
      Traitee.Cognition.UserModel.top_interests(owner_id, 5)
      |> Enum.map_join(", ", fn i -> "#{i.topic} (#{Float.round(Traitee.Cognition.Interest.score(i), 2)})" end)

    desires =
      Traitee.Cognition.UserModel.desires(owner_id)
      |> Enum.take(5)
      |> Enum.join("; ")

    dream = Traitee.Cognition.Dream.status()
    workshop = Traitee.Cognition.Workshop.status()
    meta = Traitee.Cognition.Metacognition.summary()

    text =
      "Cognition Overview\n" <>
        "\n  Top Interests: #{if interests == "", do: "(none yet)", else: interests}" <>
        "\n  Desires: #{if desires == "", do: "(none yet)", else: desires}" <>
        "\n\n  Dream: last=#{dream.last_dream || "never"}, curiosity=#{dream.curiosity_queue_size}" <>
        "\n  Workshop: building=#{workshop.current_project || "none"}, queue=#{workshop.queue_size}, done=#{workshop.completed_count}" <>
        "\n  Meta: claims=#{meta.total_claims}, calibration=#{meta.calibration_score || "n/a"}, improvements=#{meta.improvements_made}"

    {:ok, text}
  rescue
    _ -> {:ok, "Cognition not available."}
  end

  def cmd_qc(["review", id | _], _ctx) do
    case Integer.parse(id) do
      {project_id, _} ->
        Traitee.Cognition.QualityControl.review_project(project_id)
        {:ok, "QC review triggered for project ##{project_id}."}

      :error ->
        {:ok, "Usage: /qc review <project_id>"}
    end
  end

  def cmd_qc(_args, _ctx) do
    status = Traitee.Cognition.QualityControl.status()

    rate =
      case status.approval_rate do
        nil -> "n/a"
        r -> "#{Float.round(r * 100, 1)}%"
      end

    text =
      "Quality Control\n" <>
        "  Enabled: #{status.enabled}\n" <>
        "  Evaluations: #{status.evaluations}\n" <>
        "  Approved: #{status.approvals} | Rejected: #{status.rejections}\n" <>
        "  Approval rate: #{rate}"

    {:ok, text}
  rescue
    _ -> {:ok, "QC not available (cognition may be disabled)."}
  end

  # -- Helpers --

  defp configure_session(inbound, key, value) do
    session_id = build_session_id(inbound)

    case Registry.lookup(Traitee.Session.Registry, session_id) do
      [{pid, _}] -> Traitee.Session.Server.configure(pid, key, value)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp build_session_id(%{sender_id: sid, channel_type: ch}) do
    AgentRouter.build_session_key(
      "default",
      %{sender_id: sid, channel_type: ch},
      :per_peer
    )
  end

  defp build_session_id(%{sender_id: sid}) do
    AgentRouter.build_session_key(
      "default",
      %{sender_id: sid, channel_type: nil},
      :per_peer
    )
  end
end
