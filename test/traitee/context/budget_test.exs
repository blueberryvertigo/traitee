defmodule Traitee.Context.BudgetTest do
  use ExUnit.Case, async: true

  alias Traitee.Context.Budget

  describe "allocate/4" do
    test "creates a budget struct with all fields" do
      budget = Budget.allocate("openai/gpt-4o", "You are helpful.", "Hello!")
      assert %Budget{} = budget
      assert budget.total_budget > 0
      assert budget.system_prompt_tokens > 0
      assert budget.current_message_tokens > 0
      assert budget.response_budget > 0
      assert budget.safety_margin > 0
      assert budget.mode == :normal
    end

    test "all slot budgets are non-negative" do
      budget = Budget.allocate("openai/gpt-4o", "System.", "User message.")

      assert budget.skills_budget >= 0
      assert budget.ltm_budget >= 0
      assert budget.mtm_budget >= 0
      assert budget.stm_budget >= 0
      assert budget.tool_budget >= 0
      assert budget.reminder_budget >= 0
    end

    test "slot budgets sum to available variable space" do
      budget = Budget.allocate("openai/gpt-4o", "System.", "Hi!")
      variable = Budget.variable_budget(budget)
      assert variable > 0
      assert budget.remaining == variable
    end

    test "compact mode reduces allocations" do
      normal = Budget.allocate("openai/gpt-4o", "System.", "Hi!", mode: :normal)
      compact = Budget.allocate("openai/gpt-4o", "System.", "Hi!", mode: :compact)
      assert compact.ltm_budget <= normal.ltm_budget
      assert compact.mtm_budget <= normal.mtm_budget
      assert compact.mode == :compact
    end

    test "respects tool_schema_tokens option" do
      no_tools = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!")
      with_tools = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!", tool_schema_tokens: 2000)
      assert with_tools.stm_budget < no_tools.stm_budget
    end
  end

  describe "record_usage/3" do
    test "records token usage for a slot" do
      budget = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!")
      budget = Budget.record_usage(budget, :ltm, 500)
      assert budget.usage[:ltm] == 500
    end

    test "overwrites previous usage for same slot" do
      budget = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!")
      budget = Budget.record_usage(budget, :ltm, 500)
      budget = Budget.record_usage(budget, :ltm, 300)
      assert budget.usage[:ltm] == 300
    end
  end

  describe "reallocate/3" do
    test "moves surplus from one slot to another" do
      budget = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!")
      budget = Budget.record_usage(budget, :ltm, 100)
      original_stm = budget.stm_budget
      original_ltm = budget.ltm_budget

      budget = Budget.reallocate(budget, :ltm_budget, :stm_budget)
      assert budget.stm_budget > original_stm
      assert budget.ltm_budget < original_ltm
    end

    test "no-op when slot is fully used" do
      budget = Budget.allocate("openai/gpt-4o", "System prompt.", "Hello user!")
      ltm_allocated = budget.ltm_budget
      budget = Budget.record_usage(budget, :ltm, ltm_allocated)
      original_stm = budget.stm_budget

      budget = Budget.reallocate(budget, :ltm_budget, :stm_budget)
      assert budget.stm_budget >= original_stm
    end
  end

  describe "fixed_tokens/1" do
    test "sums system + message + response + safety" do
      budget = Budget.allocate("openai/gpt-4o", "System prompt.", "User message.")
      fixed = Budget.fixed_tokens(budget)

      expected =
        budget.system_prompt_tokens + budget.current_message_tokens +
          budget.response_budget + budget.safety_margin

      assert fixed == expected
    end
  end

  describe "total_used/1" do
    test "sums all usage values" do
      budget = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!")
      budget = Budget.record_usage(budget, :ltm, 100)
      budget = Budget.record_usage(budget, :mtm, 200)
      assert Budget.total_used(budget) == 300
    end

    test "returns 0 when no usage recorded" do
      budget = Budget.allocate("openai/gpt-4o", "Sys.", "Hi!")
      assert Budget.total_used(budget) == 0
    end
  end

  describe "budget_summary/1" do
    test "returns a formatted string" do
      budget = Budget.allocate("openai/gpt-4o", "System.", "Hello!")
      budget = Budget.record_usage(budget, :stm, 5000)
      summary = Budget.budget_summary(budget)

      assert is_binary(summary)
      assert summary =~ "Budget"
      assert summary =~ "normal"
      assert summary =~ "stm"
      assert summary =~ "system"
    end
  end

  describe "fit_within/2" do
    test "fits items within token budget" do
      items = [
        %{content: "short", token_count: 10},
        %{content: "medium length text", token_count: 50},
        %{content: "another", token_count: 20}
      ]

      result = Budget.fit_within(items, 35)
      assert length(result) == 2
    end

    test "returns empty for zero budget" do
      items = [%{content: "hi", token_count: 10}]
      assert Budget.fit_within(items, 0) == []
    end

    test "returns all items if they fit" do
      items = [%{token_count: 10}, %{token_count: 20}]
      result = Budget.fit_within(items, 100)
      assert length(result) == 2
    end
  end

  describe "fit_recent/2" do
    test "keeps the most recent items that fit" do
      items = [
        %{content: "old", token_count: 50},
        %{content: "middle", token_count: 50},
        %{content: "recent", token_count: 50}
      ]

      result = Budget.fit_recent(items, 60)
      assert length(result) == 1
      assert hd(result).content == "recent"
    end
  end

  describe "truncate_to_budget/2" do
    test "returns text unchanged if within budget" do
      {text, tokens} = Budget.truncate_to_budget("hello", 1000)
      assert text == "hello"
      assert tokens > 0
    end

    test "truncates text that exceeds budget" do
      long = String.duplicate("word ", 10_000)
      {text, _tokens} = Budget.truncate_to_budget(long, 10)
      assert String.contains?(text, "[truncated]")
      assert String.length(text) < String.length(long)
    end
  end
end
