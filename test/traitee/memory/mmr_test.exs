defmodule Traitee.Memory.MMRTest do
  use ExUnit.Case, async: true

  alias Traitee.Memory.MMR

  import Traitee.Fixtures

  describe "select/3" do
    test "returns empty list for empty candidates" do
      assert MMR.select([], 5) == []
    end

    test "returns empty list for k=0" do
      assert MMR.select(mmr_candidates(3), 0) == []
    end

    test "returns at most k items" do
      results = MMR.select(mmr_candidates(10), 3)
      assert length(results) == 3
    end

    test "returns all items when k >= candidate count" do
      candidates = mmr_candidates(3)
      results = MMR.select(candidates, 10)
      assert length(results) == 3
    end

    test "first item is the highest scored candidate" do
      candidates = mmr_candidates(5)
      [first | _] = MMR.select(candidates, 3)
      max_score = candidates |> Enum.map(& &1.score) |> Enum.max()
      assert first.score == max_score
    end

    test "lambda=1.0 returns pure relevance ordering" do
      candidates = mmr_candidates(5)
      results = MMR.select(candidates, 5, 1.0)
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "lambda=0.0 maximizes diversity" do
      candidates = [
        %{id: 1, score: 0.9, embedding: [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], content: "A"},
        %{id: 2, score: 0.8, embedding: [0.99, 0.01, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], content: "B"},
        %{id: 3, score: 0.7, embedding: [0.98, 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], content: "C"},
        %{id: 4, score: 0.6, embedding: [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], content: "D"},
        %{id: 5, score: 0.5, embedding: [0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0], content: "E"}
      ]

      diverse_ids = candidates |> MMR.select(3, 0.0) |> Enum.map(& &1.id)
      relevance_ids = candidates |> MMR.select(3, 1.0) |> Enum.map(& &1.id)

      assert relevance_ids == [1, 2, 3]
      assert diverse_ids != relevance_ids
      assert 1 in diverse_ids
      assert Enum.any?([4, 5], &(&1 in diverse_ids))
    end

    test "works with content-based similarity (no embeddings)" do
      candidates = [
        %{score: 0.9, content: "elixir programming language"},
        %{score: 0.8, content: "elixir programming tutorial"},
        %{score: 0.7, content: "rust systems programming"},
        %{score: 0.6, content: "python data science"}
      ]

      results = MMR.select(candidates, 2, 0.3)
      assert length(results) == 2
    end

    test "handles single candidate" do
      candidates = [%{score: 0.9, content: "single"}]
      results = MMR.select(candidates, 1)
      assert length(results) == 1
      assert hd(results).score == 0.9
    end
  end
end
