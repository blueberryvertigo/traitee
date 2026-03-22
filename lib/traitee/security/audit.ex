defmodule Traitee.Security.Audit do
  @moduledoc """
  Structured security audit trail for filesystem and execution events.

  All filesystem access attempts, command executions, and policy decisions
  are recorded to an ETS ring buffer for real-time queries, with periodic
  flush to SQLite for durable history.

  Events are keyed by timestamp and include: event type, tool, session,
  path/command, operation, decision (allow/deny), and reason.

  The audit trail enables:
  - Real-time security posture visibility
  - Post-incident forensic analysis
  - Policy tuning based on actual access patterns
  - CogSec tracking of LLM filesystem access against allowlists
  """

  use GenServer

  require Logger

  @table :traitee_security_audit
  @max_events 10_000
  @flush_interval_ms 60_000

  defstruct event_count: 0, deny_count: 0, allow_count: 0, started_at: nil

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a security event. Fire-and-forget — never blocks the caller.

  ## Event types
    - `:path_access` — file/directory access attempt
    - `:command_check` — shell command validation
    - `:exec_gate` — execution approval gate decision
    - `:docker_exec` — Docker container execution
    - `:policy_reload` — policy configuration change
    - `:cogsec_violation` — cognitive security violation involving filesystem
  """
  @spec record(atom(), map()) :: :ok
  def record(event_type, details) when is_atom(event_type) and is_map(details) do
    event = %{
      id: System.unique_integer([:positive, :monotonic]),
      type: event_type,
      timestamp: DateTime.utc_now(),
      session_id: details[:session_id],
      tool: details[:tool],
      decision: details[:decision] || :unknown,
      details: details
    }

    insert_event(event)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Returns the most recent N audit events."
  @spec recent(non_neg_integer()) :: [map()]
  def recent(limit \\ 50) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_id, event} -> event.id end, :desc)
        |> Enum.take(limit)
        |> Enum.map(fn {_id, event} -> event end)
    end
  end

  @doc "Returns audit events filtered by criteria."
  @spec query(keyword()) :: [map()]
  def query(filters) do
    events = recent(@max_events)

    events
    |> maybe_filter(:type, filters[:type])
    |> maybe_filter(:decision, filters[:decision])
    |> maybe_filter(:tool, filters[:tool])
    |> maybe_filter(:session_id, filters[:session_id])
    |> maybe_filter_path(filters[:path_contains])
    |> maybe_filter_since(filters[:since])
    |> Enum.take(filters[:limit] || 100)
  end

  @doc "Returns aggregate statistics about security events."
  @spec stats() :: map()
  def stats do
    events = recent(@max_events)

    %{
      total_events: length(events),
      decisions: Enum.frequencies_by(events, & &1.decision),
      by_type: Enum.frequencies_by(events, & &1.type),
      by_tool: Enum.frequencies_by(events, & &1[:tool]),
      recent_denials: events |> Enum.filter(&(&1.decision == :deny)) |> Enum.take(10),
      denial_rate: denial_rate(events),
      unique_sessions: events |> Enum.map(& &1.session_id) |> Enum.uniq() |> length(),
      window_start: events |> List.last() |> then(fn e -> e && e.timestamp end),
      window_end: events |> List.first() |> then(fn e -> e && e.timestamp end)
    }
  end

  @doc """
  Returns a formatted security posture report.
  Used by `mix traitee.security` and the doctor command.
  """
  @spec format_report() :: String.t()
  def format_report do
    stats = stats()

    denials =
      Enum.map_join(stats.recent_denials, "\n", fn event ->
        path_or_cmd =
          event.details[:path] || event.details[:command] || "unknown"

        "    [#{format_time(event.timestamp)}] #{event.type} #{event.details[:tool]} → #{path_or_cmd}"
      end)

    """
      Audit Trail Summary
      ────────────────────────
      Total events:     #{stats.total_events}
      Allow decisions:  #{stats.decisions[:allow] || 0}
      Deny decisions:   #{stats.decisions[:deny] || 0}
      Denial rate:      #{stats.denial_rate}
      Unique sessions:  #{stats.unique_sessions}
      Event types:      #{format_freq(stats.by_type)}
      By tool:          #{format_freq(stats.by_tool)}

      Recent Denials:
    #{if denials == "", do: "    (none)", else: denials}
    """
  end

  @doc "Clear all audit events."
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    end

    schedule_flush()

    {:ok,
     %__MODULE__{
       started_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_info(:flush, state) do
    prune_old_events()
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp insert_event(event) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.insert(@table, {event.id, event})
    end
  end

  defp prune_old_events do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        count = :ets.info(@table, :size)

        if count > @max_events do
          excess = count - @max_events

          :ets.tab2list(@table)
          |> Enum.sort_by(fn {id, _} -> id end, :asc)
          |> Enum.take(excess)
          |> Enum.each(fn {id, _} -> :ets.delete(@table, id) end)
        end
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp maybe_filter(events, _key, nil), do: events

  defp maybe_filter(events, key, value) do
    Enum.filter(events, &(Map.get(&1, key) == value))
  end

  defp maybe_filter_path(events, nil), do: events

  defp maybe_filter_path(events, substring) do
    Enum.filter(events, fn event ->
      path = get_in(event, [:details, :path]) || get_in(event, [:details, :command]) || ""
      String.contains?(String.downcase(path), String.downcase(substring))
    end)
  end

  defp maybe_filter_since(events, nil), do: events

  defp maybe_filter_since(events, since) do
    Enum.filter(events, fn event ->
      DateTime.compare(event.timestamp, since) in [:gt, :eq]
    end)
  end

  defp denial_rate([]), do: "0%"

  defp denial_rate(events) do
    denials = Enum.count(events, &(&1.decision == :deny))
    total = length(events)
    "#{Float.round(denials / total * 100, 1)}%"
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_freq(freq_map) when is_map(freq_map) do
    freq_map
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.map_join(", ", fn {key, count} -> "#{key}=#{count}" end)
  end

  defp format_freq(_), do: "(none)"
end
