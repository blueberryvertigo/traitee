defmodule Traitee.Security.ThreatTracker do
  @moduledoc """
  ETS-backed per-session threat accumulator with rolling score and temporal decay.

  Tracks threat events across a session's lifetime and computes an aggregate
  threat level that downstream systems (persistent reminders, output guard)
  use to calibrate their response intensity.
  """

  alias Traitee.Security.Sanitizer.Threat

  @table :traitee_threat_tracker
  @decay_half_life_ms 10 * 60 * 1_000
  @severity_weight %{low: 1, medium: 3, high: 7, critical: 15}

  @type threat_level :: :normal | :elevated | :high | :critical
  @type event :: %{
          threat: Threat.t(),
          timestamp: integer()
        }

  def init do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @spec record(String.t(), Threat.t()) :: :ok
  def record(session_id, %Threat{} = threat) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    event = %{threat: threat, timestamp: now}

    events =
      case :ets.lookup(@table, session_id) do
        [{^session_id, existing}] -> existing ++ [event]
        [] -> [event]
      end

    :ets.insert(@table, {session_id, events})
    :ok
  end

  @spec record_all(String.t(), [Threat.t()]) :: :ok
  def record_all(_session_id, []), do: :ok

  def record_all(session_id, threats) when is_list(threats) do
    Enum.each(threats, &record(session_id, &1))
  end

  @spec threat_level(String.t()) :: threat_level()
  def threat_level(session_id) do
    score = threat_score(session_id)

    cond do
      score >= 30 -> :critical
      score >= 15 -> :high
      score >= 5 -> :elevated
      true -> :normal
    end
  end

  @spec threat_score(String.t()) :: float()
  def threat_score(session_id) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, session_id) do
      [{^session_id, events}] ->
        events
        |> Enum.map(fn %{threat: t, timestamp: ts} ->
          weight = Map.get(@severity_weight, t.severity, 1)
          age_ms = max(now - ts, 0)
          decay = :math.pow(0.5, age_ms / @decay_half_life_ms)
          weight * decay
        end)
        |> Enum.sum()

      [] ->
        0.0
    end
  end

  @spec events(String.t()) :: [event()]
  def events(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, events}] -> events
      [] -> []
    end
  end

  @spec event_count(String.t()) :: non_neg_integer()
  def event_count(session_id) do
    events(session_id) |> length()
  end

  @spec categories_seen(String.t()) :: [atom()]
  def categories_seen(session_id) do
    events(session_id)
    |> Enum.map(& &1.threat.category)
    |> Enum.uniq()
  end

  @spec clear(String.t()) :: :ok
  def clear(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  @spec summary(String.t()) :: String.t()
  def summary(session_id) do
    level = threat_level(session_id)
    score = threat_score(session_id) |> Float.round(1)
    count = event_count(session_id)
    cats = categories_seen(session_id) |> Enum.map_join(", ", &Atom.to_string/1)

    "threat_level=#{level} score=#{score} events=#{count} categories=[#{cats}]"
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined, do: init()
  end
end
