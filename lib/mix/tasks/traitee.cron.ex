defmodule Mix.Tasks.Traitee.Cron do
  @moduledoc """
  Manage scheduled jobs.

      mix traitee.cron list
      mix traitee.cron add <name> <schedule> <message>
      mix traitee.cron remove <name>
      mix traitee.cron run <name>
      mix traitee.cron pause <name>
      mix traitee.cron resume <name>
  """
  use Mix.Task

  alias Traitee.Cron.Scheduler

  @shortdoc "Manage scheduled jobs"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["list" | _] -> list_jobs()
      ["add", name, schedule | message_parts] -> add_job(name, schedule, message_parts)
      ["remove", name] -> remove_job(name)
      ["run", name] -> run_job(name)
      ["pause", name] -> pause_job(name)
      ["resume", name] -> resume_job(name)
      _ -> usage()
    end
  end

  defp list_jobs do
    jobs = Scheduler.list_jobs()

    if jobs == [] do
      IO.puts("\nNo scheduled jobs.")
    else
      IO.puts("\nScheduled Jobs")
      IO.puts("═══════════════════════")

      Enum.each(jobs, fn job ->
        status = if job.enabled, do: "active", else: "paused"
        next = if job.next_run_at, do: DateTime.to_string(job.next_run_at), else: "—"

        IO.puts("  #{job.name} [#{job.job_type}] #{status}")
        IO.puts("    Schedule: #{job.schedule}")
        IO.puts("    Next run: #{next}")
        IO.puts("    Runs: #{job.run_count}, Errors: #{job.consecutive_errors}")
        IO.puts("")
      end)
    end
  end

  defp add_job(name, schedule, message_parts) do
    message = Enum.join(message_parts, " ")
    job_type = detect_type(schedule)

    attrs = %{
      name: name,
      job_type: job_type,
      schedule: schedule,
      payload: %{"message" => message},
      enabled: true
    }

    case Scheduler.add_job(attrs) do
      {:ok, job} ->
        IO.puts("Job '#{job.name}' added (#{job_type}, next: #{job.next_run_at || "now"})")

      {:error, changeset} ->
        IO.puts("Error: #{inspect(changeset.errors)}")
    end
  end

  defp remove_job(name) do
    case Scheduler.remove_job(name) do
      :ok -> IO.puts("Job '#{name}' removed.")
      {:error, :not_found} -> IO.puts("Job '#{name}' not found.")
    end
  end

  defp run_job(name) do
    case Scheduler.run_job(name) do
      :ok -> IO.puts("Job '#{name}' executed.")
      {:error, :not_found} -> IO.puts("Job '#{name}' not found.")
    end
  end

  defp pause_job(name) do
    case Scheduler.pause_job(name) do
      :ok -> IO.puts("Job '#{name}' paused.")
      {:error, :not_found} -> IO.puts("Job '#{name}' not found.")
    end
  end

  defp resume_job(name) do
    case Scheduler.resume_job(name) do
      :ok -> IO.puts("Job '#{name}' resumed.")
      {:error, :not_found} -> IO.puts("Job '#{name}' not found.")
    end
  end

  defp detect_type(schedule) do
    cond do
      Regex.match?(~r/^\d{4}-/, schedule) -> "at"
      Regex.match?(~r/^\d+$/, schedule) -> "every"
      true -> "cron"
    end
  end

  defp usage do
    IO.puts("""

    Usage: mix traitee.cron <command>

    Commands:
      list                          Show all scheduled jobs
      add <name> <schedule> <msg>   Add a new job
      remove <name>                 Remove a job
      run <name>                    Force-execute a job now
      pause <name>                  Pause a job
      resume <name>                 Resume a paused job

    Schedule formats:
      "*/5 * * * *"        Cron expression (every 5 minutes)
      "60000"              Interval in milliseconds
      "2026-03-21T10:00:00Z"  One-shot at specific time
    """)
  end
end
