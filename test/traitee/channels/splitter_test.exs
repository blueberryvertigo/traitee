defmodule Traitee.Channels.SplitterTest do
  use ExUnit.Case, async: true

  alias Traitee.Channels.Splitter

  describe "split_message/2" do
    test "returns short text unchanged as a single part" do
      assert Splitter.split_message("hello", 100) == ["hello"]
    end

    test "returns empty string unchanged" do
      assert Splitter.split_message("", 100) == [""]
    end

    test "returns text exactly at the limit unchanged" do
      text = String.duplicate("a", 10)
      assert Splitter.split_message(text, 10) == [text]
    end

    test "prefers paragraph boundaries" do
      text = "first paragraph\n\nsecond paragraph"
      assert Splitter.split_message(text, 20) == ["first paragraph", "second paragraph"]
    end

    test "prefers newline boundaries when no paragraph break fits" do
      text = "line one\nline two\nline three"
      assert Splitter.split_message(text, 20) == ["line one\nline two", "line three"]
    end

    test "prefers word boundaries when no newline fits" do
      text = "alpha beta gamma delta"
      assert Splitter.split_message(text, 12) == ["alpha beta", "gamma delta"]
    end

    test "hard-splits unbroken text as a last resort" do
      text = String.duplicate("a", 10)
      assert Splitter.split_message(text, 4) == ["aaaa", "aaaa", "aa"]
    end

    test "every part respects the limit" do
      text = Enum.map_join(1..50, " ", fn i -> "word#{i}" end)

      for limit <- [10, 25, 80] do
        parts = Splitter.split_message(text, limit)
        assert Enum.all?(parts, &(String.length(&1) <= limit))
      end
    end

    test "preserves all non-whitespace content" do
      text = "para one\n\npara two\nline three and some longer words to split apart"
      parts = Splitter.split_message(text, 12)

      normalize = fn s -> s |> String.split(~r/\s+/, trim: true) |> Enum.join(" ") end
      assert normalize.(Enum.join(parts, " ")) == normalize.(text)
    end
  end
end
