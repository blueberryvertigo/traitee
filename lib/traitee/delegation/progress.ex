defmodule Traitee.Delegation.Progress do
  @moduledoc """
  ETS-backed real-time progress tracker for delegated subagents.

  Each running subagent writes its current state (round, tool count,
  status) to an ETS table keyed by `{session_id, tag}`. The parent
  session can read this at any time via `get_all/1` or `format_status/1`
  without blocking the subagent.
  """

  @table :traitee_delegation_progress

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @doc "Merge progress fields for a subagent. Creates the entry if it doesn't exist."
  def update(nil, _tag, _fields), do: :ok

  def update(session_id, tag, fields) when is_map(fields) do
    key = {session_id, tag}

    existing =
      case :ets.lookup(@table, key) do
        [{^key, entry}] -> entry
        [] -> %{tag: tag, session_id: session_id, started_at: System.monotonic_time(:millisecond)}
      end

    updated =
      Map.merge(existing, Map.put(fields, :last_activity_at, System.monotonic_time(:millisecond)))

    :ets.insert(@table, {key, updated})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Returns all active subagent entries for a session."
  def get_all(session_id) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      :ets.match_object(@table, {{session_id, :_}, :_})
      |> Enum.map(fn {_key, entry} -> entry end)
      |> Enum.sort_by(& &1.tag)
    end
  rescue
    _ -> []
  end

  @doc "Remove a single subagent's progress entry."
  def clear(session_id, tag) do
    :ets.delete(@table, {session_id, tag})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Remove all progress entries for a session."
  def clear_session(session_id) do
    entries = :ets.match(@table, {{session_id, :"$1"}, :_})
    Enum.each(entries, fn [tag] -> :ets.delete(@table, {session_id, tag}) end)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Human-readable progress summary for all subagents in a session."
  def format_status(session_id) do
    entries = get_all(session_id)

    if entries == [] do
      "No active subagents."
    else
      now = System.monotonic_time(:millisecond)

      lines =
        Enum.map(entries, fn e ->
          elapsed = div(now - (e[:started_at] || now), 1000)
          status = e[:status] || "unknown"

          parts = [
            "[#{e.tag}] #{status}",
            round_part(e),
            tool_part(e),
            "(#{elapsed}s)"
          ]

          parts |> Enum.reject(&is_nil/1) |> Enum.join(", ")
        end)

      Enum.join(lines, "\n")
    end
  end

  defp round_part(%{round: r, max_rounds: m}) when is_integer(r) and is_integer(m),
    do: "round #{r}/#{m}"

  defp round_part(_), do: nil

  defp tool_part(%{tool_count: tc, last_tool: lt}) when is_integer(tc) and tc > 0,
    do: "#{tc} tool calls, last: #{lt}"

  defp tool_part(%{tool_count: tc}) when is_integer(tc) and tc > 0,
    do: "#{tc} tool calls"

  defp tool_part(_), do: nil
end
