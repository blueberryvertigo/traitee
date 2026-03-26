defmodule Traitee.Context.StatusBarTest do
  use ExUnit.Case, async: true

  alias Traitee.Context.{StatusBar, Budget}

  defp build_budget(opts \\ []) do
    total = opts[:total] || 128_000
    used_stm = opts[:stm_used] || 5_000

    budget = Budget.allocate("openai/gpt-4o", "You are helpful.", "Hello!")
    budget = %{budget | total_budget: total}
    Budget.record_usage(budget, :stm, used_stm)
  end

  describe "from_session/1" do
    test "computes idle state for low STM fill" do
      data = StatusBar.from_session(%{stm_count: 10, stm_capacity: 50})
      assert data.compaction_state == :idle
    end

    test "computes near state at 75%+ STM fill" do
      data = StatusBar.from_session(%{stm_count: 38, stm_capacity: 50})
      assert data.compaction_state == :near
    end

    test "computes critical state at 90%+ STM fill" do
      data = StatusBar.from_session(%{stm_count: 46, stm_capacity: 50})
      assert data.compaction_state == :critical
    end

    test "preserves compacting state from session" do
      data = StatusBar.from_session(%{
        stm_count: 10,
        stm_capacity: 50,
        compaction_state: :compacting
      })
      assert data.compaction_state == :compacting
    end

    test "preserves compacted state from session" do
      data = StatusBar.from_session(%{
        stm_count: 10,
        stm_capacity: 50,
        compaction_state: :compacted
      })
      assert data.compaction_state == :compacted
    end

    test "sets defaults for missing fields" do
      data = StatusBar.from_session(%{})
      assert data.model == "unknown"
      assert data.stm_count == 0
      assert data.stm_capacity == 50
      assert data.budget == nil
    end
  end

  describe "render/1" do
    test "includes model name" do
      data = StatusBar.from_session(%{model: "openai/gpt-4o", stm_count: 10, stm_capacity: 50})
      rendered = StatusBar.render(data)
      assert rendered =~ "openai/gpt-4o"
    end

    test "includes token counts when budget is present" do
      budget = build_budget()

      data = StatusBar.from_session(%{
        model: "openai/gpt-4o",
        budget: budget,
        stm_count: 20,
        stm_capacity: 50
      })

      rendered = StatusBar.render(data)
      assert rendered =~ "/128.0K"
      assert rendered =~ "%"
    end

    test "includes STM segment" do
      data = StatusBar.from_session(%{stm_count: 34, stm_capacity: 50})
      rendered = StatusBar.render(data)
      assert rendered =~ "stm 34/50"
    end

    test "includes compaction warning when near" do
      data = StatusBar.from_session(%{stm_count: 40, stm_capacity: 50})
      rendered = StatusBar.render(data)
      assert rendered =~ "compact soon"
    end

    test "includes compaction critical warning" do
      data = StatusBar.from_session(%{stm_count: 47, stm_capacity: 50})
      rendered = StatusBar.render(data)
      assert rendered =~ "compact imminent"
    end

    test "omits compaction segment when idle" do
      data = StatusBar.from_session(%{stm_count: 10, stm_capacity: 50})
      rendered = StatusBar.render(data)
      refute rendered =~ "compact"
    end

    test "shows elapsed time" do
      start = DateTime.add(DateTime.utc_now(), -300, :second)

      data = StatusBar.from_session(%{
        stm_count: 10,
        stm_capacity: 50,
        session_start: start
      })

      rendered = StatusBar.render(data)
      assert rendered =~ "5m"
    end

    test "shows progress bar with budget" do
      budget = build_budget()

      data = StatusBar.from_session(%{
        model: "openai/gpt-4o",
        budget: budget,
        stm_count: 10,
        stm_capacity: 50
      })

      rendered = StatusBar.render(data)
      assert rendered =~ "█"
      assert rendered =~ "░"
    end
  end

  describe "render_ansi/1" do
    test "returns IO data with ANSI escape codes" do
      budget = build_budget()

      data = StatusBar.from_session(%{
        model: "openai/gpt-4o",
        budget: budget,
        stm_count: 20,
        stm_capacity: 50,
        session_start: DateTime.utc_now()
      })

      ansi = StatusBar.render_ansi(data)
      output = IO.iodata_to_binary(ansi)
      assert output =~ "\e["
      assert output =~ "openai/gpt-4o"
      assert output =~ "stm 20/50"
    end

    test "uses green color for low utilization" do
      budget = build_budget(stm_used: 1_000)

      data = StatusBar.from_session(%{
        model: "test",
        budget: budget,
        stm_count: 5,
        stm_capacity: 50
      })

      output = IO.iodata_to_binary(StatusBar.render_ansi(data))
      assert output =~ "\e[32m"
    end
  end
end
