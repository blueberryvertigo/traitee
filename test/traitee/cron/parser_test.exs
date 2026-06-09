defmodule Traitee.Cron.ParserTest do
  use ExUnit.Case, async: true

  alias Traitee.Cron.Parser

  describe "parse/1" do
    test "parses wildcard expression" do
      assert {:ok, expr} = Parser.parse("* * * * *")
      assert expr.minute == Enum.to_list(0..59)
      assert expr.hour == Enum.to_list(0..23)
      assert expr.day == Enum.to_list(1..31)
      assert expr.month == Enum.to_list(1..12)
      assert expr.weekday == Enum.to_list(0..6)
    end

    test "parses specific values" do
      assert {:ok, expr} = Parser.parse("30 9 15 6 3")
      assert expr.minute == [30]
      assert expr.hour == [9]
      assert expr.day == [15]
      assert expr.month == [6]
      assert expr.weekday == [3]
    end

    test "parses ranges" do
      assert {:ok, expr} = Parser.parse("0-15 9-17 * * 1-5")
      assert expr.minute == Enum.to_list(0..15)
      assert expr.hour == Enum.to_list(9..17)
      assert expr.weekday == Enum.to_list(1..5)
    end

    test "parses step values" do
      assert {:ok, expr} = Parser.parse("*/15 */2 * * *")
      assert expr.minute == [0, 15, 30, 45]
      assert expr.hour == [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22]
    end

    test "parses comma-separated lists" do
      assert {:ok, expr} = Parser.parse("0,15,30,45 * * * *")
      assert expr.minute == [0, 15, 30, 45]
    end

    test "parses mixed ranges and values" do
      assert {:ok, expr} = Parser.parse("0,30 9-17 1,15 * 1-5")
      assert expr.minute == [0, 30]
      assert expr.hour == Enum.to_list(9..17)
      assert expr.day == [1, 15]
      assert expr.weekday == Enum.to_list(1..5)
    end

    test "rejects invalid field count" do
      assert {:error, msg} = Parser.parse("* * *")
      assert msg =~ "expected 5 fields"
    end

    test "rejects out-of-range values" do
      assert {:error, _} = Parser.parse("60 * * * *")
      assert {:error, _} = Parser.parse("* 24 * * *")
      assert {:error, _} = Parser.parse("* * 32 * *")
      assert {:error, _} = Parser.parse("* * * 13 *")
      assert {:error, _} = Parser.parse("* * * * 7")
    end

    test "rejects invalid step" do
      assert {:error, _} = Parser.parse("*/0 * * * *")
      assert {:error, _} = Parser.parse("*/abc * * * *")
    end

    test "rejects invalid range" do
      assert {:error, _} = Parser.parse("10-5 * * * *")
    end

    test "handles extra whitespace" do
      assert {:ok, _} = Parser.parse("  0   9   *   *   1  ")
    end
  end

  describe "matches?/2" do
    test "matches a specific datetime" do
      {:ok, expr} = Parser.parse("30 9 * * *")
      dt = ~U[2026-03-21 09:30:00Z]
      assert Parser.matches?(expr, dt)
    end

    test "does not match wrong minute" do
      {:ok, expr} = Parser.parse("30 9 * * *")
      dt = ~U[2026-03-21 09:00:00Z]
      refute Parser.matches?(expr, dt)
    end

    test "does not match wrong weekday" do
      {:ok, expr} = Parser.parse("* * * * 1-5")
      # 2026-03-22 is a Sunday (weekday 0)
      dt = ~U[2026-03-22 12:00:00Z]
      refute Parser.matches?(expr, dt)
    end

    test "matches wildcard for all fields" do
      {:ok, expr} = Parser.parse("* * * * *")
      assert Parser.matches?(expr, DateTime.utc_now())
    end
  end

  describe "next_occurrence/2" do
    test "finds the next minute match" do
      {:ok, expr} = Parser.parse("30 * * * *")
      from = ~U[2026-03-21 10:00:00Z]
      {:ok, next} = Parser.next_occurrence(expr, from)
      assert next.minute == 30
      assert next.hour == 10
    end

    test "rolls to next hour if needed" do
      {:ok, expr} = Parser.parse("0 * * * *")
      from = ~U[2026-03-21 10:30:00Z]
      {:ok, next} = Parser.next_occurrence(expr, from)
      assert next.minute == 0
      assert next.hour == 11
    end

    test "rolls to next day if needed" do
      {:ok, expr} = Parser.parse("0 9 * * *")
      from = ~U[2026-03-21 10:00:00Z]
      {:ok, next} = Parser.next_occurrence(expr, from)
      assert next.minute == 0
      assert next.hour == 9
      assert next.day == 22
    end

    test "respects weekday constraints" do
      {:ok, expr} = Parser.parse("0 9 * * 1")
      from = ~U[2026-03-21 10:00:00Z]
      {:ok, next} = Parser.next_occurrence(expr, from)
      assert Date.day_of_week(next) == 1
    end

    test "returns a time after the input" do
      {:ok, expr} = Parser.parse("*/5 * * * *")
      from = DateTime.utc_now()
      {:ok, next} = Parser.next_occurrence(expr, from)
      assert DateTime.compare(next, from) == :gt
    end

    test "returns an error for unsatisfiable schedules instead of raising" do
      # February 31st never exists.
      {:ok, expr} = Parser.parse("0 0 31 2 *")
      assert {:error, :unsatisfiable} = Parser.next_occurrence(expr, ~U[2026-01-01 00:00:00Z])
    end
  end

  describe "day-of-month / day-of-week OR semantics" do
    # Standard cron: when BOTH fields are restricted, either may match.
    # 2026-01-02 is a Friday; 2026-01-13 is a Tuesday.

    test "matches when day-of-month matches but weekday does not" do
      {:ok, expr} = Parser.parse("0 0 13 * 5")
      dt = ~U[2026-01-13 00:00:00Z]
      assert Date.day_of_week(dt) != 5
      assert Parser.matches?(expr, dt)
    end

    test "matches when weekday matches but day-of-month does not" do
      {:ok, expr} = Parser.parse("0 0 13 * 5")
      dt = ~U[2026-01-02 00:00:00Z]
      assert Date.day_of_week(dt) == 5
      assert Parser.matches?(expr, dt)
    end

    test "does not match when neither field matches" do
      {:ok, expr} = Parser.parse("0 0 13 * 5")
      # 2026-01-01 is a Thursday and not the 13th.
      refute Parser.matches?(expr, ~U[2026-01-01 00:00:00Z])
    end

    test "keeps AND semantics when weekday is a wildcard" do
      {:ok, expr} = Parser.parse("0 0 13 * *")
      assert Parser.matches?(expr, ~U[2026-01-13 00:00:00Z])
      refute Parser.matches?(expr, ~U[2026-01-02 00:00:00Z])
    end

    test "keeps AND semantics when day-of-month is a wildcard" do
      {:ok, expr} = Parser.parse("0 0 * * 5")
      assert Parser.matches?(expr, ~U[2026-01-02 00:00:00Z])
      refute Parser.matches?(expr, ~U[2026-01-01 00:00:00Z])
    end

    test "next_occurrence honors OR semantics when both fields are restricted" do
      {:ok, expr} = Parser.parse("0 0 13 * 5")
      {:ok, next} = Parser.next_occurrence(expr, ~U[2026-01-01 00:00:00Z])
      # Friday Jan 2 comes before the 13th.
      assert next == ~U[2026-01-02 00:00:00Z]
    end

    test "parse records restriction flags" do
      {:ok, both} = Parser.parse("0 0 13 * 5")
      assert both.day_restricted?
      assert both.weekday_restricted?

      {:ok, wild} = Parser.parse("0 0 * * *")
      refute wild.day_restricted?
      refute wild.weekday_restricted?
    end
  end
end
