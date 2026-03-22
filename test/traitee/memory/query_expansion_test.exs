defmodule Traitee.Memory.QueryExpansionTest do
  use ExUnit.Case, async: true

  alias Traitee.Memory.QueryExpansion

  describe "expand/1" do
    test "always includes the original message" do
      result = QueryExpansion.expand("hello world")
      assert "hello world" in result
    end

    test "returns at most 5 queries" do
      long =
        "What is the Elixir programming language used for in Phoenix LiveView and Ecto ORM development?"

      result = QueryExpansion.expand(long)
      assert length(result) <= 5
    end

    test "extracts quoted phrases" do
      result = QueryExpansion.expand(~s(tell me about "machine learning" and "neural networks"))
      combined = Enum.join(result, " ")
      assert String.contains?(combined, "machine learning")
      assert String.contains?(combined, "neural networks")
    end

    test "extracts capitalized proper nouns" do
      result = QueryExpansion.expand("What did John Smith say about Project Alpha?")
      combined = Enum.join(result, " ")

      assert String.contains?(combined, "John Smith") or
               String.contains?(combined, "Project Alpha")
    end

    test "extracts keywords (filters stop words)" do
      result = QueryExpansion.expand("what is the best programming language for web development")
      combined = Enum.join(result, " ")
      assert String.contains?(combined, "programming")
      assert String.contains?(combined, "language")
    end

    test "extracts question subjects" do
      result = QueryExpansion.expand("What is Elixir?")
      combined = Enum.join(result, " ")
      assert String.contains?(combined, "Elixir")
    end

    test "handles 'tell me about' pattern" do
      result = QueryExpansion.expand("tell me about distributed systems")
      combined = Enum.join(result, " ")
      assert String.contains?(combined, "distributed systems")
    end

    test "handles 'how to' pattern" do
      result = QueryExpansion.expand("how to deploy an Elixir application")
      combined = Enum.join(result, " ")
      assert String.contains?(combined, "deploy")
    end

    test "deduplicates results" do
      result = QueryExpansion.expand("Elixir Elixir Elixir")
      assert result == Enum.uniq(result)
    end

    test "handles empty-ish input" do
      result = QueryExpansion.expand("a the is")
      assert is_list(result)
    end
  end
end
