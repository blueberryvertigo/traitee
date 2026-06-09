defmodule Traitee.Cron.Scheduler do
  @moduledoc "Persistent job scheduler with one-shot, interval, and cron expression support."
  use GenServer

  alias Traitee.Cron.{Parser, Schema}
  alias Traitee.Repo

  import Ecto.Query

  require Logger

  @tick_interval_ms :timer.seconds(15)
  @session_ttl_hours 24

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec add_job(map()) :: {:ok, Schema.t()} | {:error, Ecto.Changeset.t()}
  def add_job(attrs) do
    attrs = Map.put_new(attrs, :next_run_at, compute_next_run(attrs))

    %Schema{}
    |> Schema.changeset(attrs)
    |> Repo.insert()
  end

  @spec remove_job(String.t()) :: :ok | {:error, :not_found}
  def remove_job(name) do
    case Repo.get_by(Schema, name: name) do
      nil -> {:error, :not_found}
      job -> Repo.delete(job) |> then(fn {:ok, _} -> :ok end)
    end
  end

  @spec list_jobs() :: [Schema.t()]
  def list_jobs do
    Schema |> order_by(:name) |> Repo.all()
  end

  @spec pause_job(String.t()) :: :ok | {:error, :not_found}
  def pause_job(name), do: set_enabled(name, false)

  @spec resume_job(String.t()) :: :ok | {:error, :not_found}
  def resume_job(name), do: set_enabled(name, true)

  @spec run_job(String.t()) :: :ok | {:error, :not_found}
  def run_job(name) do
    case Repo.get_by(Schema, name: name) do
      nil -> {:error, :not_found}
      job -> execute_job(job)
    end
  end

  # -- Server --

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      now = DateTime.utc_now()

      Schema
      |> where([j], j.enabled == true and (is_nil(j.next_run_at) or j.next_run_at <= ^now))
      |> Repo.all()
      |> Enum.each(&safe_execute_and_reschedule/1)

      reap_sessions()
    rescue
      # Broad rescue: any exception escaping the tick would crash the
      # scheduler into a restart/re-execute loop.
      e ->
        Logger.warning("Scheduler tick failed: #{Exception.message(e)}")
    end

    schedule_tick()
    {:noreply, state}
  end

  # -- Private --

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  # Isolate each job so one bad job can't kill the whole tick. On error,
  # disable the job — leaving it due would re-execute it every 15s.
  defp safe_execute_and_reschedule(job) do
    execute_and_reschedule(job)
  rescue
    e ->
      Logger.error("Cron job #{job.name} scheduling failed, disabling: #{Exception.message(e)}")
      disable_job_on_error(job, Exception.message(e))
  end

  defp execute_and_reschedule(job) do
    now = DateTime.utc_now()
    updates = reschedule_updates(job, now)

    # Persist next_run_at BEFORE executing: if execution crashes the
    # process, the job must not be due again on the next tick.
    case job |> Schema.changeset(updates) |> Repo.update() do
      {:ok, updated} -> dispatch_job(updated)
      {:error, _changeset} -> dispatch_job(job)
    end
  end

  # Execute asynchronously — Session.Server.send_message can block for
  # minutes, which used to stall the tick and serialize all due jobs.
  defp dispatch_job(job) do
    Task.start(fn -> execute_job(job) end)
  end

  defp reschedule_updates(job, now) do
    case job.job_type do
      "at" ->
        %{enabled: false, last_run_at: now, run_count: job.run_count + 1}

      "every" ->
        interval_ms = parse_interval(job.schedule)
        next = DateTime.add(now, interval_ms, :millisecond)
        %{last_run_at: now, next_run_at: next, run_count: job.run_count + 1}

      "cron" ->
        cron_reschedule_updates(job, now)
    end
  end

  defp cron_reschedule_updates(job, now) do
    with {:ok, expr} <- Parser.parse(job.schedule),
         {:ok, next} <- Parser.next_occurrence(expr, now) do
      %{last_run_at: now, next_run_at: next, run_count: job.run_count + 1}
    else
      {:error, :unsatisfiable} ->
        %{
          enabled: false,
          last_run_at: now,
          run_count: job.run_count + 1,
          consecutive_errors: job.consecutive_errors + 1,
          last_error: "unsatisfiable cron expression"
        }

      {:error, _} ->
        %{
          last_run_at: now,
          run_count: job.run_count + 1,
          consecutive_errors: job.consecutive_errors + 1,
          last_error: "invalid cron expression"
        }
    end
  end

  defp disable_job_on_error(job, message) do
    job
    |> Schema.changeset(%{
      enabled: false,
      consecutive_errors: job.consecutive_errors + 1,
      last_error: message
    })
    |> Repo.update()
  rescue
    _ -> :ok
  end

  defp execute_job(job) do
    message = job.payload["message"] || inspect(job.payload)
    # Defensive: use String.to_existing_atom in a try-rescue so a malformed
    # persisted channel doesn't crash the scheduler.
    channel =
      try do
        if job.channel, do: String.to_existing_atom(job.channel), else: :cli
      rescue
        ArgumentError -> :cli
      end

    target = job.target || "cron:#{job.name}"

    case Traitee.Session.ensure_started(target, channel) do
      {:ok, pid} ->
        # Cron-fired messages bypass the inbound Router (no channel
        # handshake exists for an OS-scheduled job). To preserve the
        # cognitive-security pipeline, we go through
        # Session.Server.send_message which still runs Sanitizer/Judge/
        # ThreatTracker and threat-gating inside the session.
        #
        # Tag the delivery so the session's owner-check sees this call
        # as system-originated rather than attacker-originated.
        Traitee.Session.Server.send_message(pid, message, channel,
          sender_id: "cron:#{job.name}",
          reply_to: nil
        )

        Logger.info("Cron job #{job.name} executed")

      {:error, reason} ->
        Logger.error("Cron job #{job.name} failed to start session: #{inspect(reason)}")
        mark_error(job, inspect(reason))
    end
  rescue
    e ->
      Logger.error("Cron job #{job.name} failed: #{Exception.message(e)}")
      mark_error(job, Exception.message(e))
  end

  defp mark_error(job, message) do
    job
    |> Schema.changeset(%{
      consecutive_errors: job.consecutive_errors + 1,
      last_error: message
    })
    |> Repo.update()
  end

  defp set_enabled(name, enabled) do
    case Repo.get_by(Schema, name: name) do
      nil ->
        {:error, :not_found}

      job ->
        job
        |> Schema.changeset(%{enabled: enabled})
        |> Repo.update()
        |> then(fn {:ok, _} -> :ok end)
    end
  end

  defp compute_next_run(%{job_type: "at", schedule: schedule}) do
    case DateTime.from_iso8601(schedule) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp compute_next_run(%{job_type: "every", schedule: schedule}) do
    DateTime.add(DateTime.utc_now(), parse_interval(schedule), :millisecond)
  end

  defp compute_next_run(%{job_type: "cron", schedule: schedule}) do
    with {:ok, expr} <- Parser.parse(schedule),
         {:ok, next} <- Parser.next_occurrence(expr, DateTime.utc_now()) do
      next
    else
      _ -> nil
    end
  end

  defp compute_next_run(_), do: nil

  defp parse_interval(schedule) when is_binary(schedule) do
    case Integer.parse(schedule) do
      {ms, ""} -> ms
      _ -> 60_000
    end
  end

  defp parse_interval(schedule) when is_integer(schedule), do: schedule

  defp reap_sessions do
    ttl_hours = Traitee.Config.get([:session_ttl_hours]) || @session_ttl_hours
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_hours * 3600, :second)

    Traitee.Memory.Schema.Session
    |> where([s], s.status == "active" and s.last_activity < ^cutoff)
    |> Repo.all()
    |> Enum.each(fn session ->
      Traitee.Session.terminate(session.session_id)
      session |> Ecto.Changeset.change(%{status: "reaped"}) |> Repo.update()
      Logger.info("Reaped inactive session: #{session.session_id}")
    end)
  end
end
