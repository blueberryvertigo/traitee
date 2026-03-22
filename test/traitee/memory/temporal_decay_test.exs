defmodule Traitee.Memory.TemporalDecayTest do
  use ExUnit.Case, async: true

  alias Traitee.Memory.TemporalDecay

  describe "apply/2" do
    test "recent items keep high scores" do
      items = [
        %{score: 1.0, timestamp: DateTime.utc_now(), id: 1},
        %{score: 0.8, timestamp: DateTime.utc_now(), id: 2}
      ]

      result = TemporalDecay.apply(items)
      assert length(result) == 2
      first = hd(result)
      assert first.score > 0.95
    end

    test "older items get lower scores" do
      now = DateTime.utc_now()
      week_ago = DateTime.add(now, -7 * 24 * 3600, :second)
      month_ago = DateTime.add(now, -30 * 24 * 3600, :second)

      items = [
        %{score: 1.0, timestamp: now, id: :recent},
        %{score: 1.0, timestamp: week_ago, id: :week_old},
        %{score: 1.0, timestamp: month_ago, id: :month_old}
      ]

      result = TemporalDecay.apply(items)

      scores = Map.new(result, fn r -> {r.id, r.score} end)
      assert scores[:recent] > scores[:week_old]
      assert scores[:week_old] > scores[:month_old]
    end

    test "results are sorted by decayed score descending" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -30 * 24 * 3600, :second)

      items = [
        %{score: 0.5, timestamp: now, id: :recent_low},
        %{score: 1.0, timestamp: old, id: :old_high}
      ]

      result = TemporalDecay.apply(items)
      scores = Enum.map(result, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "respects min_weight floor" do
      very_old = DateTime.add(DateTime.utc_now(), -365 * 24 * 3600, :second)
      items = [%{score: 1.0, timestamp: very_old, id: :ancient}]

      result = TemporalDecay.apply(items, min_weight: 0.1)
      assert hd(result).score >= 0.1
    end

    test "custom half_life changes decay rate" do
      day_ago = DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
      items = [%{score: 1.0, timestamp: day_ago, id: :test}]

      fast_decay = TemporalDecay.apply(items, half_life_hours: 24)
      slow_decay = TemporalDecay.apply(items, half_life_hours: 8760)

      assert hd(fast_decay).score < hd(slow_decay).score
    end

    test "nil timestamp treated as age 0" do
      items = [%{score: 1.0, timestamp: nil, id: :nil_ts}]
      result = TemporalDecay.apply(items)
      assert hd(result).score == 1.0
    end

    test "handles empty list" do
      assert TemporalDecay.apply([]) == []
    end

    test "preserves all item fields" do
      items = [
        %{
          score: 1.0,
          timestamp: DateTime.utc_now(),
          id: :test,
          content: "hello",
          source: :summary
        }
      ]

      result = TemporalDecay.apply(items)
      item = hd(result)
      assert item.id == :test
      assert item.content == "hello"
      assert item.source == :summary
    end
  end
end
