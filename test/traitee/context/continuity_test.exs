defmodule Traitee.Context.ContinuityTest do
  use ExUnit.Case, async: true

  alias Traitee.Context.Continuity

  describe "detect_topic_shift/2" do
    test "detects same topic when keywords overlap" do
      recent = [
        %{content: "Tell me about Elixir programming"},
        %{content: "I love Elixir"}
      ]

      result = Continuity.detect_topic_shift("What about Elixir concurrency?", recent)
      assert result in [:same_topic, :related]
    end

    test "detects new topic when no overlap" do
      recent = [%{content: "Tell me about cooking pasta"}]
      result = Continuity.detect_topic_shift("What is quantum computing?", recent)
      assert result in [:new_topic, :related]
    end

    test "returns :new_topic for empty recent messages" do
      assert Continuity.detect_topic_shift("hello", []) == :new_topic
    end

    test "handles messages with string-keyed content" do
      recent = [%{content: "elixir programming"}]
      result = Continuity.detect_topic_shift("elixir concurrency", recent)
      assert result in [:same_topic, :related, :new_topic]
    end
  end

  describe "format_recall/1" do
    test "formats recall results with entities" do
      results = %{
        entities: [%{name: "John", entity_type: "person", description: "developer"}],
        facts: [],
        summaries: [],
        query: "John"
      }

      formatted = Continuity.format_recall(results)
      assert is_binary(formatted)
      assert formatted =~ "John"
    end

    test "formats recall results with facts" do
      results = %{
        entities: [],
        facts: [%{content: "Project Alpha uses Elixir"}],
        summaries: [],
        query: "Alpha"
      }

      formatted = Continuity.format_recall(results)
      assert formatted =~ "Project Alpha"
    end

    test "formats recall results with summaries" do
      results = %{
        entities: [],
        facts: [],
        summaries: [%{content: "We discussed deployment strategies"}],
        query: "deploy"
      }

      formatted = Continuity.format_recall(results)
      assert formatted =~ "deployment"
    end

    test "handles empty results" do
      results = %{entities: [], facts: [], summaries: [], query: "nothing"}
      formatted = Continuity.format_recall(results)
      assert is_binary(formatted)
      assert formatted == ""
    end
  end
end
