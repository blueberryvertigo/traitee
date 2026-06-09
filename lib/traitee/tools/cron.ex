defmodule Traitee.Tools.Cron do
  @moduledoc "LLM-callable tool for managing scheduled cron jobs."

  @behaviour Traitee.Tools.Tool

  alias Traitee.Cron.Scheduler
  alias Traitee.Security.ToolGate

  @impl true
  def name, do: "cron"

  @impl true
  def description do
    "Manage scheduled jobs. Use 'list' to see jobs, 'add' to create recurring or one-shot jobs, " <>
      "'remove' to delete, 'run' to execute immediately, 'pause'/'resume' to toggle."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "add", "remove", "run", "pause", "resume"],
          "description" => "Action to perform"
        },
        "name" => %{
          "type" => "string",
          "description" => "Job name (required for add/remove/run/pause/resume)"
        },
        "schedule" => %{
          "type" => "string",
          "description" =>
            "Schedule: cron expression (\"*/5 * * * *\"), interval in ms (\"60000\"), or ISO8601 datetime for one-shot"
        },
        "message" => %{
          "type" => "string",
          "description" => "Message to send to the session when the job fires"
        },
        "channel" => %{
          "type" => "string",
          "description" => "Channel to deliver on (optional, defaults to cli)"
        },
        "target" => %{
          "type" => "string",
          "description" => "Target session ID (optional, defaults to cron:<name>)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "list"}) do
    jobs = Scheduler.list_jobs()

    if jobs == [] do
      {:ok, "No scheduled jobs."}
    else
      lines =
        Enum.map(jobs, fn job ->
          status = if job.enabled, do: "active", else: "paused"
          next = if job.next_run_at, do: DateTime.to_string(job.next_run_at), else: "-"

          "#{job.name} [#{job.job_type}] #{status} | schedule: #{job.schedule} | next: #{next} | runs: #{job.run_count}"
        end)

      {:ok, Enum.join(lines, "\n")}
    end
  end

  def execute(
        %{"action" => "add", "name" => name, "schedule" => schedule, "message" => message} = args
      )
      when is_binary(name) and is_binary(schedule) and is_binary(message) do
    # Previously the LLM could pick an arbitrary target session id and
    # channel for the cron to fire into. That lets it schedule jobs that
    # reach OTHER users' sessions with arbitrary content. We force the
    # target to the current session and require owner auth to cross-
    # target another session or channel.
    case authorize_add(args) do
      :ok -> create_job(name, schedule, message, args)
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{"action" => "add"}) do
    {:error, "Missing required parameters: name, schedule, message"}
  end

  def execute(%{"action" => "remove", "name" => name}) when is_binary(name) do
    case Scheduler.remove_job(name) do
      :ok -> {:ok, "Job '#{name}' removed."}
      {:error, :not_found} -> {:error, "Job '#{name}' not found."}
    end
  end

  def execute(%{"action" => "run", "name" => name}) when is_binary(name) do
    case Scheduler.run_job(name) do
      :ok -> {:ok, "Job '#{name}' executed."}
      {:error, :not_found} -> {:error, "Job '#{name}' not found."}
    end
  end

  def execute(%{"action" => "pause", "name" => name}) when is_binary(name) do
    case Scheduler.pause_job(name) do
      :ok -> {:ok, "Job '#{name}' paused."}
      {:error, :not_found} -> {:error, "Job '#{name}' not found."}
    end
  end

  def execute(%{"action" => "resume", "name" => name}) when is_binary(name) do
    case Scheduler.resume_job(name) do
      :ok -> {:ok, "Job '#{name}' resumed."}
      {:error, :not_found} -> {:error, "Job '#{name}' not found."}
    end
  end

  def execute(%{"action" => action}) when action in ~w(remove run pause resume) do
    {:error, "Missing required parameter: name"}
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  defp authorize_add(args) do
    if cross_target?(args) or cross_channel?(args) do
      ToolGate.require_owner(args, "cron")
    else
      :ok
    end
  end

  defp cross_target?(args) do
    requested_target = args["target"]

    is_binary(requested_target) and requested_target != "" and
      requested_target != args["_session_id"]
  end

  defp cross_channel?(args) do
    requested_channel = args["channel"]

    is_binary(requested_channel) and requested_channel != "" and
      to_string(args["_session_channel_type"]) != requested_channel
  end

  defp create_job(name, schedule, message, args) do
    job_type = detect_type(schedule)

    attrs = %{
      name: name,
      job_type: job_type,
      schedule: schedule,
      payload: %{"message" => message},
      channel: resolve_job_channel(args),
      target: resolve_job_target(args, name),
      enabled: true
    }

    case Scheduler.add_job(attrs) do
      {:ok, job} ->
        {:ok, "Job '#{job.name}' created (#{job_type}, next: #{job.next_run_at || "now"})"}

      {:error, changeset} ->
        {:error, "Failed to create job: #{inspect(changeset.errors)}"}
    end
  end

  defp resolve_job_target(args, name) do
    if cross_target?(args) do
      args["target"]
    else
      args["_session_id"] || "cron:#{name}"
    end
  end

  defp resolve_job_channel(args) do
    requested_channel = args["channel"]
    session_channel = args["_session_channel_type"]

    cond do
      is_binary(requested_channel) and requested_channel != "" -> requested_channel
      session_channel != nil -> to_string(session_channel)
      true -> "cli"
    end
  end

  defp detect_type(schedule) do
    cond do
      Regex.match?(~r/^\d{4}-/, schedule) -> "at"
      Regex.match?(~r/^\d+$/, schedule) -> "every"
      true -> "cron"
    end
  end
end
