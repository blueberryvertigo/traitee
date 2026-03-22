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

  def cmd_model([name | _], _ctx) do
    {:ok, "Model set to: #{name} (takes effect next message)"}
  end

  def cmd_think([], _ctx), do: {:ok, "Usage: /think off|low|medium|high"}

  def cmd_think([level | _], _ctx) when level in ~w(off minimal low medium high) do
    {:ok, "Thinking level set to: #{level}"}
  end

  def cmd_think(_, _ctx), do: {:ok, "Valid levels: off, minimal, low, medium, high"}

  def cmd_verbose([], _ctx), do: {:ok, "Usage: /verbose on|off"}

  def cmd_verbose([mode | _], _ctx) when mode in ~w(on off) do
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

  # -- Helpers --

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
