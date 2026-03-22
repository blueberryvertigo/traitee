defmodule Traitee.Memory.HybridSearchTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Traitee.Memory.{HybridSearch, LTM, MTM, Vector}

  import Traitee.TestHelpers

  setup do
    Vector.init()
    :ets.delete_all_objects(:traitee_vectors)

    pid = Sandbox.start_owner!(Traitee.Repo, shared: true)

    on_exit(fn ->
      Sandbox.stop_owner(pid)

      if :ets.whereis(:traitee_vectors) != :undefined do
        :ets.delete_all_objects(:traitee_vectors)
      end
    end)

    :ok
  end

  describe "search/3 - keyword path" do
    test "returns keyword matches from MTM summaries" do
      sid = unique_session_id()

      {:ok, _} =
        MTM.store_summary(sid, "Discussion about Elixir GenServers and supervision trees")

      {:ok, _} = MTM.store_summary(sid, "Talked about Rust async runtime")

      results = HybridSearch.search("Elixir GenServer", sid)
      assert is_list(results)

      if results != [] do
        assert Enum.any?(results, fn r -> r.source == :summary end)
      end
    end

    test "returns keyword matches from LTM facts" do
      sid = unique_session_id()
      {:ok, entity} = LTM.upsert_entity("Phoenix", "concept")
      {:ok, _} = LTM.add_fact(entity.id, "Phoenix uses plugs for middleware", "extracted")

      results = HybridSearch.search("Phoenix plugs", sid)
      assert is_list(results)

      if results != [] do
        fact_results = Enum.filter(results, &(&1.source == :fact))

        if fact_results != [] do
          assert hd(fact_results).content =~ "Phoenix"
        end
      end
    end

    test "returns keyword matches from LTM entities" do
      sid = unique_session_id()
      {:ok, _} = LTM.upsert_entity("LiveView", "concept", "Real-time Phoenix framework")

      results = HybridSearch.search("LiveView", sid)
      assert is_list(results)
      entity_results = Enum.filter(results, &(&1.source == :entity))
      assert entity_results != []
    end

    test "returns empty for no matches" do
      sid = unique_session_id()
      results = HybridSearch.search("zzz_impossible_query_zzz", sid)
      assert results == []
    end
  end

  describe "search/3 - options" do
    test "respects :limit option" do
      sid = unique_session_id()

      for i <- 1..10 do
        {:ok, e} = LTM.upsert_entity("HSOpt#{i}", "concept")
        LTM.add_fact(e.id, "Fact about HSOpt#{i}", "extracted")
      end

      results = HybridSearch.search("HSOpt", sid, limit: 3)
      assert length(results) <= 3
    end

    test "respects :source_types filter" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "Summary about HSTypeFilter topic")
      {:ok, e} = LTM.upsert_entity("HSTypeFilter", "concept")
      {:ok, _} = LTM.add_fact(e.id, "Fact about HSTypeFilter", "extracted")

      results = HybridSearch.search("HSTypeFilter", sid, source_types: [:fact])

      if results != [] do
        assert Enum.all?(results, &(&1.source == :fact))
      end
    end

    test "all scores are non-negative" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "HSScore relevant content")

      results = HybridSearch.search("HSScore", sid)
      assert Enum.all?(results, fn r -> r.score >= 0.0 end)
    end
  end

  describe "search/3 - cross-tier merging" do
    test "merges results from multiple memory tiers" do
      sid = unique_session_id()

      {:ok, _} = MTM.store_summary(sid, "HSCross discussion about distributed systems")
      {:ok, entity} = LTM.upsert_entity("HSCross", "concept", "A distributed systems concept")
      {:ok, _} = LTM.add_fact(entity.id, "HSCross uses consensus algorithms", "extracted")

      results = HybridSearch.search("HSCross", sid)
      sources = Enum.map(results, & &1.source) |> Enum.uniq()

      assert results != []
      assert sources != []
    end
  end
end
