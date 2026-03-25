defmodule Traitee.ActivityLog do
  @moduledoc """
  Non-blocking activity logger. Records tool calls, subagent dispatches,
  LLM calls, and session events without slowing down the chat loop.

  Uses direct ETS inserts (nanosecond writes from any process) with an
  auto-incrementing counter for ordering. No GenServer needed for writes.
  """

  require Logger

  @table :traitee_activity_log
  @counter :traitee_activity_log_counter
  @max_entries_per_session 500

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :ordered_set, :public, write_concurrency: true])
    end

    if :ets.whereis(@counter) == :undefined do
      :ets.new(@counter, [:named_table, :set, :public, write_concurrency: true])
      :ets.insert(@counter, {:seq, 0})
    end

    :ok
  end

  @doc """
  Record an activity event. Returns immediately (never blocks).

  ## Event types
    - :tool_call — tool execution (name, args_summary, status, duration_ms)
    - :llm_call — LLM completion (model, tokens, latency_ms)
    - :subagent_dispatch — subagent started (tags, tools)
    - :subagent_complete — subagent finished (tag, status, duration_ms)
    - :session_event — session lifecycle (event: start/end/reset, message_count)
  """
  def record(session_id, event_type, details \\ %{}) when is_atom(event_type) do
    seq = :ets.update_counter(@counter, :seq, 1)

    entry = %{
      id: seq,
      session_id: session_id,
      event_type: event_type,
      details: details,
      timestamp: System.system_time(:millisecond)
    }

    :ets.insert(@table, {{session_id, seq}, entry})

    maybe_evict(session_id, seq)

    :ok
  rescue
    _ -> :ok
  end

  @doc "Returns the most recent N entries for a session."
  def recent(session_id, limit \\ 20) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      match_spec = [
        {{{session_id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}
      ]

      :ets.select(@table, match_spec)
      |> Enum.sort_by(fn {seq, _} -> seq end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_seq, entry} -> entry end)
    end
  end

  @doc "Returns aggregate stats for a session."
  def summary(session_id) do
    entries = recent(session_id, @max_entries_per_session)

    tool_calls = Enum.filter(entries, &(&1.event_type == :tool_call))
    llm_calls = Enum.filter(entries, &(&1.event_type == :llm_call))

    tool_counts =
      tool_calls
      |> Enum.group_by(& &1.details[:name])
      |> Enum.map(fn {name, calls} -> {name, length(calls)} end)
      |> Enum.into(%{})

    avg_llm_latency =
      case llm_calls do
        [] ->
          0

        calls ->
          total = Enum.sum(Enum.map(calls, &(&1.details[:latency_ms] || 0)))
          div(total, length(calls))
      end

    %{
      total_events: length(entries),
      tool_calls: length(tool_calls),
      tool_counts: tool_counts,
      llm_calls: length(llm_calls),
      avg_llm_latency_ms: avg_llm_latency
    }
  end

  defp maybe_evict(session_id, current_seq) do
    if rem(current_seq, 100) == 0 do
      Task.start(fn -> evict_old(session_id) end)
    end
  end

  defp evict_old(session_id) do
    match_spec = [
      {{{session_id, :"$1"}, :_}, [], [:"$1"]}
    ]

    seqs = :ets.select(@table, match_spec) |> Enum.sort()

    if length(seqs) > @max_entries_per_session do
      to_delete = Enum.take(seqs, length(seqs) - @max_entries_per_session)
      Enum.each(to_delete, fn seq -> :ets.delete(@table, {session_id, seq}) end)
    end
  rescue
    _ -> :ok
  end
end
