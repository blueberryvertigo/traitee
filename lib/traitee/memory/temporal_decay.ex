defmodule Traitee.Memory.TemporalDecay do
  @moduledoc "Temporal decay scoring - exponential decay based on age of memory."

  @default_half_life_hours 168
  @default_min_weight 0.1

  @doc """
  Applies exponential temporal decay to a list of scored items.

  Each item must have `:score` (float) and `:timestamp` (DateTime).
  Returns items with updated `:score`, sorted by new score descending.

  Options:
  - `:half_life_hours` - hours until score halves (default 168 = 1 week)
  - `:min_weight` - floor for the decay multiplier (default 0.1)
  """
  def apply(items, opts \\ []) do
    half_life = opts[:half_life_hours] || @default_half_life_hours
    min_weight = opts[:min_weight] || @default_min_weight
    now = DateTime.utc_now()

    items
    |> Enum.map(fn item ->
      age_hours = age_in_hours(item.timestamp, now)
      decay = max(min_weight, :math.pow(2, -age_hours / half_life))
      %{item | score: item.score * decay}
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp age_in_hours(nil, _now), do: 0.0

  defp age_in_hours(timestamp, now) do
    DateTime.diff(now, timestamp, :second) / 3600.0
  end
end
