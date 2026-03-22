defmodule Traitee.Memory.VectorTest do
  use ExUnit.Case, async: false

  import Traitee.TestHelpers

  alias Traitee.Memory.Vector

  setup do
    Vector.init()
    :ets.delete_all_objects(:traitee_vectors)

    on_exit(fn ->
      if :ets.whereis(:traitee_vectors) != :undefined do
        :ets.delete_all_objects(:traitee_vectors)
      end
    end)

    :ok
  end

  describe "init/0" do
    test "creates the ETS table" do
      assert :ets.whereis(:traitee_vectors) != :undefined
    end

    test "is idempotent" do
      assert Vector.init() == :ok
      assert Vector.init() == :ok
    end
  end

  describe "store/3 and get_embedding/2" do
    test "stores and retrieves an embedding" do
      emb = fake_embedding(8)
      assert Vector.store(:summary, 1, emb) == :ok
      assert {:ok, ^emb} = Vector.get_embedding(:summary, 1)
    end

    test "returns :not_found for missing embedding" do
      assert Vector.get_embedding(:summary, 999) == :not_found
    end

    test "overwrites existing embedding" do
      emb1 = fake_embedding(8)
      emb2 = fake_embedding(8)
      Vector.store(:summary, 1, emb1)
      Vector.store(:summary, 1, emb2)
      assert {:ok, ^emb2} = Vector.get_embedding(:summary, 1)
    end

    test "handles nil embedding gracefully" do
      assert Vector.store(:summary, 1, nil) == :ok
    end
  end

  describe "delete/2" do
    test "removes a stored embedding" do
      Vector.store(:fact, 1, fake_embedding(8))
      assert {:ok, _} = Vector.get_embedding(:fact, 1)
      assert Vector.delete(:fact, 1) == :ok
      assert Vector.get_embedding(:fact, 1) == :not_found
    end
  end

  describe "search/3" do
    test "finds stored vectors" do
      # Use unique IDs to avoid collision with parallel tests
      id1 = :erlang.unique_integer([:positive])
      id2 = id1 + 1
      emb1 = normalize_embedding(fake_embedding(8))
      emb2 = normalize_embedding(fake_embedding(8))

      Vector.store(:summary, id1, emb1)
      Vector.store(:summary, id2, emb2)

      results = Vector.search(emb1, 100)
      my_results = Enum.filter(results, fn {_, id, _} -> id in [id1, id2] end)
      assert my_results != []
      [{_, _, score1} | _] = my_results
      assert score1 > 0
    end

    test "respects k limit" do
      base = List.duplicate(1.0, 8)

      for i <- 1..10 do
        emb = List.update_at(base, rem(i, 8), fn v -> v + i * 0.01 end)
        Vector.store(:fact, "klimit_#{i}", emb)
      end

      results = Vector.search(base, 3)
      assert length(results) == 3
    end

    test "filters by source_type" do
      Vector.store(:summary, 1, fake_embedding(8))
      Vector.store(:fact, 2, fake_embedding(8))
      Vector.store(:entity, 3, fake_embedding(8))

      results = Vector.search(fake_embedding(8), 10, source_type: :fact)
      assert Enum.all?(results, fn {type, _, _} -> type == :fact end)
    end

    test "respects min_score threshold" do
      Vector.store(:summary, 1, fake_embedding(8))
      results = Vector.search(fake_embedding(8), 10, min_score: 0.99)
      assert Enum.all?(results, fn {_, _, score} -> score >= 0.99 end)
    end

    test "returns empty list when no vectors stored" do
      assert Vector.search(fake_embedding(8), 5) == []
    end
  end

  describe "bulk_store/1" do
    test "stores multiple embeddings at once" do
      items = for i <- 1..5, do: {:summary, i, fake_embedding(8)}
      assert Vector.bulk_store(items) == :ok
      assert Vector.count() == 5
    end
  end

  describe "count/0" do
    test "returns total vector count" do
      assert Vector.count() == 0
      Vector.store(:summary, 1, fake_embedding(8))
      assert Vector.count() == 1
    end
  end

  describe "stats/0" do
    test "returns breakdown by source type" do
      Vector.store(:summary, 1, fake_embedding(8))
      Vector.store(:summary, 2, fake_embedding(8))
      Vector.store(:fact, 3, fake_embedding(8))

      stats = Vector.stats()
      assert stats.total == 3
      assert stats.by_type[:summary] == 2
      assert stats.by_type[:fact] == 1
    end
  end

  describe "search_with_mmr/4" do
    test "returns diverse results" do
      for i <- 1..10 do
        Vector.store(:summary, i, fake_embedding(8))
      end

      query = fake_embedding(8)
      results = Vector.search_with_mmr(query, 3, 0.5)
      assert length(results) <= 3
      assert Enum.all?(results, fn r -> Map.has_key?(r, :score) end)
    end
  end
end
