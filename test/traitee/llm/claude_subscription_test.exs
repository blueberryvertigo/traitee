defmodule Traitee.LLM.ClaudeSubscriptionTest do
  use ExUnit.Case, async: true

  alias Traitee.LLM.ClaudeSubscription
  alias Traitee.LLM.Types.ModelInfo

  describe "model_info/1" do
    test "returns zero-cost models" do
      info = ClaudeSubscription.model_info("claude-sonnet-4")
      assert %ModelInfo{} = info
      assert info.provider == :claude_subscription
      assert info.cost_per_1k_input == 0.0
      assert info.cost_per_1k_output == 0.0
      assert info.supports_tools == true
    end

    test "returns default for unknown model" do
      info = ClaudeSubscription.model_info("unknown-model")
      assert info.provider == :claude_subscription
      assert info.cost_per_1k_input == 0.0
    end

    test "known models have correct IDs" do
      assert ClaudeSubscription.model_info("claude-opus-4.6").id == "claude-opus-4-6"
      assert ClaudeSubscription.model_info("claude-sonnet-4").id == "claude-sonnet-4-20250514"
      assert ClaudeSubscription.model_info("claude-opus-4").id == "claude-opus-4-20250514"
      assert ClaudeSubscription.model_info("claude-haiku-3.5").id == "claude-3-5-haiku-20241022"
    end
  end

  describe "embed/1" do
    test "returns not_supported" do
      assert {:error, :not_supported} = ClaudeSubscription.embed(["test"])
    end
  end
end
