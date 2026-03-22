defmodule Traitee.LLM.TokenizerTest do
  use ExUnit.Case, async: true

  alias Traitee.LLM.Tokenizer

  describe "count_tokens/1" do
    test "returns positive integer for non-empty text" do
      count = Tokenizer.count_tokens("Hello, world!")
      assert is_integer(count)
      assert count > 0
    end

    test "longer text has more tokens" do
      short = Tokenizer.count_tokens("hi")

      long =
        Tokenizer.count_tokens("This is a significantly longer piece of text with many words")

      assert long > short
    end

    test "returns 0 for nil" do
      assert Tokenizer.count_tokens(nil) == 0
    end

    test "handles empty string" do
      count = Tokenizer.count_tokens("")
      assert is_integer(count)
    end

    test "handles unicode text" do
      count = Tokenizer.count_tokens("こんにちは世界")
      assert is_integer(count)
      assert count > 0
    end

    test "approximation is in reasonable range" do
      text = String.duplicate("a", 400)
      count = Tokenizer.count_tokens(text)
      assert count >= 100 and count <= 120
    end
  end

  describe "count_messages/1" do
    test "counts token across message list" do
      messages = [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "Hello!"},
        %{role: "assistant", content: "Hi there!"}
      ]

      count = Tokenizer.count_messages(messages)
      assert is_integer(count)
      assert count > 0
    end

    test "returns base overhead for empty list" do
      count = Tokenizer.count_messages([])
      assert count == 3
    end

    test "handles string-keyed maps" do
      messages = [%{"role" => "user", "content" => "Hello!"}]
      count = Tokenizer.count_messages(messages)
      assert is_integer(count)
      assert count > 3
    end

    test "handles messages without content" do
      messages = [%{role: "user"}]
      count = Tokenizer.count_messages(messages)
      assert is_integer(count)
    end
  end

  describe "count_tool/1" do
    test "counts tokens in a tool schema" do
      tool = %{
        type: "function",
        function: %{
          name: "get_weather",
          description: "Get current weather",
          parameters: %{type: "object", properties: %{location: %{type: "string"}}}
        }
      }

      count = Tokenizer.count_tool(tool)
      assert is_integer(count)
      assert count > 0
    end
  end
end
