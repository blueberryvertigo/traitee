defmodule Traitee.Context.StatusBar do
  @moduledoc """
  Renders a terminal status bar showing context window utilization,
  compaction proximity, and session metadata.

  Outputs a line like:
    openai/gpt-4o | 24.1K/128K | [████████░░░░░░░░] 19% | ⚙ stm 34/50 | 8m
  """

  alias Traitee.Context.Budget

  @bar_width 16
  @compaction_warn_threshold 0.75
  @compaction_critical_threshold 0.90

  @type status_data :: %{
          model: String.t(),
          budget: Budget.t() | nil,
          stm_count: non_neg_integer(),
          stm_capacity: non_neg_integer(),
          session_start: DateTime.t() | nil,
          compaction_state: :idle | :near | :critical | :compacting | :compacted
        }

  @spec render(status_data()) :: String.t()
  def render(data) do
    parts =
      [
        model_segment(data),
        token_segment(data),
        bar_segment(data),
        stm_segment(data),
        compaction_segment(data),
        elapsed_segment(data)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " | ")
  end

  @spec render_ansi(status_data()) :: IO.chardata()
  def render_ansi(data) do
    parts =
      [
        ansi_model(data),
        ansi_tokens(data),
        ansi_bar(data),
        ansi_stm(data),
        ansi_compaction(data),
        ansi_elapsed(data)
      ]
      |> Enum.reject(&is_nil/1)

    ["\e[90m" | Enum.intersperse(parts, "\e[90m | ")] ++ ["\e[0m"]
  end

  @doc "Computes a status_data map from raw session info."
  @spec from_session(map()) :: status_data()
  def from_session(info) do
    stm_count = info[:stm_count] || 0
    stm_capacity = info[:stm_capacity] || 50
    fill = if stm_capacity > 0, do: stm_count / stm_capacity, else: 0.0

    compaction_state =
      cond do
        info[:compaction_state] == :compacting -> :compacting
        info[:compaction_state] == :compacted -> :compacted
        fill >= @compaction_critical_threshold -> :critical
        fill >= @compaction_warn_threshold -> :near
        true -> :idle
      end

    %{
      model: info[:model] || "unknown",
      budget: info[:budget],
      stm_count: stm_count,
      stm_capacity: stm_capacity,
      session_start: info[:session_start],
      compaction_state: compaction_state
    }
  end

  # -- Segments --

  defp model_segment(%{model: model}) do
    model
    |> String.replace(~r/^(openai|anthropic|ollama|xai)\//, "\\1/")
    |> truncate_model(24)
  end

  defp token_segment(%{budget: nil}), do: nil

  defp token_segment(%{budget: budget}) do
    used = Budget.fixed_tokens(budget) + Budget.total_used(budget)
    total = budget.total_budget
    "#{format_tokens(used)}/#{format_tokens(total)}"
  end

  defp bar_segment(%{budget: nil}), do: nil

  defp bar_segment(%{budget: budget}) do
    used = Budget.fixed_tokens(budget) + Budget.total_used(budget)
    pct = min(used / max(budget.total_budget, 1), 1.0)
    filled = round(pct * @bar_width)
    empty = @bar_width - filled
    percent = round(pct * 100)

    "[#{String.duplicate("█", filled)}#{String.duplicate("░", empty)}] #{percent}%"
  end

  defp stm_segment(%{stm_count: count, stm_capacity: cap}) do
    "stm #{count}/#{cap}"
  end

  defp compaction_segment(%{compaction_state: :idle}), do: nil
  defp compaction_segment(%{compaction_state: :near}), do: "compact soon"
  defp compaction_segment(%{compaction_state: :critical}), do: "compact imminent"
  defp compaction_segment(%{compaction_state: :compacting}), do: "compacting..."
  defp compaction_segment(%{compaction_state: :compacted}), do: "compacted ✓"

  defp elapsed_segment(%{session_start: nil}), do: nil

  defp elapsed_segment(%{session_start: start}) do
    secs = DateTime.diff(DateTime.utc_now(), start, :second)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h#{rem(div(secs, 60), 60)}m"
    end
  end

  # -- ANSI colored variants --

  defp ansi_model(%{model: model}) do
    name =
      model
      |> String.replace(~r/^(openai|anthropic|ollama|xai)\//, "\\1/")
      |> truncate_model(24)

    ["\e[33m", name]
  end

  defp ansi_tokens(%{budget: nil}), do: nil

  defp ansi_tokens(%{budget: budget}) do
    used = Budget.fixed_tokens(budget) + Budget.total_used(budget)
    total = budget.total_budget
    pct = used / max(total, 1)
    color = token_color(pct)
    [color, "#{format_tokens(used)}/#{format_tokens(total)}"]
  end

  defp ansi_bar(%{budget: nil}), do: nil

  defp ansi_bar(%{budget: budget}) do
    used = Budget.fixed_tokens(budget) + Budget.total_used(budget)
    pct = min(used / max(budget.total_budget, 1), 1.0)
    filled = round(pct * @bar_width)
    empty = @bar_width - filled
    percent = round(pct * 100)
    color = token_color(pct)

    [
      "\e[90m[\e[0m",
      color,
      String.duplicate("█", filled),
      "\e[90m",
      String.duplicate("░", empty),
      "\e[90m]\e[0m ",
      color,
      "#{percent}%"
    ]
  end

  defp ansi_stm(%{stm_count: count, stm_capacity: cap}) do
    fill = count / max(cap, 1)
    color = stm_color(fill)
    [color, "stm #{count}/#{cap}"]
  end

  defp ansi_compaction(%{compaction_state: :idle}), do: nil
  defp ansi_compaction(%{compaction_state: :near}), do: ["\e[33m", "compact soon"]
  defp ansi_compaction(%{compaction_state: :critical}), do: ["\e[31m", "compact imminent"]
  defp ansi_compaction(%{compaction_state: :compacting}), do: ["\e[36m", "compacting..."]
  defp ansi_compaction(%{compaction_state: :compacted}), do: ["\e[32m", "compacted ✓"]

  defp ansi_elapsed(%{session_start: nil}), do: nil

  defp ansi_elapsed(%{session_start: start}) do
    secs = DateTime.diff(DateTime.utc_now(), start, :second)

    text =
      cond do
        secs < 60 -> "#{secs}s"
        secs < 3600 -> "#{div(secs, 60)}m"
        true -> "#{div(secs, 3600)}h#{rem(div(secs, 60), 60)}m"
      end

    ["\e[90m", text]
  end

  # -- Helpers --

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

  defp truncate_model(name, max_len) do
    if String.length(name) > max_len do
      String.slice(name, 0, max_len - 1) <> "…"
    else
      name
    end
  end

  defp token_color(pct) when pct >= 0.85, do: "\e[31m"
  defp token_color(pct) when pct >= 0.65, do: "\e[33m"
  defp token_color(_pct), do: "\e[32m"

  defp stm_color(fill) when fill >= 0.90, do: "\e[31m"
  defp stm_color(fill) when fill >= 0.75, do: "\e[33m"
  defp stm_color(_fill), do: "\e[90m"
end
