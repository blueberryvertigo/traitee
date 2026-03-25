defmodule Traitee.LLM.ProviderTest do
  use ExUnit.Case, async: true

  alias Traitee.LLM.Provider

  describe "parse_model/1" do
    test "parses openai models" do
      assert {:ok, {Traitee.LLM.OpenAI, "gpt-4o"}} = Provider.parse_model("openai/gpt-4o")

      assert {:ok, {Traitee.LLM.OpenAI, "gpt-4o-mini"}} =
               Provider.parse_model("openai/gpt-4o-mini")

      assert {:ok, {Traitee.LLM.OpenAI, "o3-mini"}} = Provider.parse_model("openai/o3-mini")
    end

    test "parses anthropic models" do
      assert {:ok, {Traitee.LLM.Anthropic, "claude-sonnet-4"}} =
               Provider.parse_model("anthropic/claude-sonnet-4")

      assert {:ok, {Traitee.LLM.Anthropic, "claude-opus-4-6"}} =
               Provider.parse_model("anthropic/claude-opus-4-6")
    end

    test "parses ollama models" do
      assert {:ok, {Traitee.LLM.Ollama, "llama3"}} = Provider.parse_model("ollama/llama3")

      assert {:ok, {Traitee.LLM.Ollama, "codellama:7b"}} =
               Provider.parse_model("ollama/codellama:7b")
    end

    test "parses xai models" do
      assert {:ok, {Traitee.LLM.XAI, "grok-4-1-fast"}} = Provider.parse_model("xai/grok-4-1-fast")
    end

    test "parses subscription models" do
      assert {:ok, {Traitee.LLM.ClaudeSubscription, "claude-sonnet-4"}} =
               Provider.parse_model("sub/claude-sonnet-4")

      assert {:ok, {Traitee.LLM.ClaudeSubscription, "claude-opus-4.6"}} =
               Provider.parse_model("sub/claude-opus-4.6")
    end

    test "returns error for unknown provider" do
      assert {:error, {:unknown_provider, "google/gemini-pro"}} =
               Provider.parse_model("google/gemini-pro")
    end

    test "returns error for malformed model strings" do
      assert {:error, {:unknown_provider, "just-a-model"}} =
               Provider.parse_model("just-a-model")

      assert {:error, {:unknown_provider, ""}} = Provider.parse_model("")
    end

    test "handles model names with slashes after provider" do
      assert {:ok, {Traitee.LLM.OpenAI, "ft:gpt-4o:custom:suffix"}} =
               Provider.parse_model("openai/ft:gpt-4o:custom:suffix")
    end
  end
end
