defmodule Traitee.Memory.Vector do
  @moduledoc """
  Vector index for semantic retrieval across all memory tiers.

  Stores embeddings in an ETS table and performs cosine similarity
  search. Embeddings are normalized to unit length on insert, so
  similarity reduces to a single-pass dot product over float lists.
  For datasets under 100k vectors, this in-memory approach is fast
  enough without external dependencies.
  """

  @table :traitee_vectors

  @doc """
  Initializes the vector index ETS table.
  Called at application startup.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Stores an embedding vector for a given source type and ID.
  Source types: :message, :summary, :fact, :entity

  The vector is normalized to unit length before storage so searches
  only need a dot product.
  """
  def store(source_type, source_id, embedding) when is_list(embedding) do
    key = {source_type, source_id}
    :ets.insert(@table, {key, normalize(embedding)})
    :ok
  end

  def store(_source_type, _source_id, nil), do: :ok

  @doc """
  Removes an embedding.
  """
  def delete(source_type, source_id) do
    init()
    :ets.delete(@table, {source_type, source_id})
    :ok
  end

  @doc """
  Finds the top K most similar items to the query embedding.
  Returns a list of `{source_type, source_id, similarity_score}` tuples,
  sorted by descending similarity.

  Options:
  - `:source_type` -- filter to a specific type (:summary, :fact, etc.)
  - `:min_score` -- minimum similarity threshold (default 0.0)
  """
  def search(query_embedding, k \\ 10, opts \\ []) do
    init()

    filter_type = opts[:source_type]
    min_score = opts[:min_score] || 0.0

    query = query_embedding |> to_float_list() |> normalize()

    @table
    |> :ets.tab2list()
    |> maybe_filter_type(filter_type)
    |> Enum.map(fn {{stype, sid}, embedding} ->
      {stype, sid, dot_product(query, embedding)}
    end)
    |> Enum.filter(fn {_, _, score} -> score >= min_score end)
    |> Enum.sort_by(fn {_, _, score} -> score end, :desc)
    |> Enum.take(k)
  end

  @doc """
  Retrieves a stored embedding for a given source type and ID.
  Note: stored embeddings are unit-normalized.
  """
  def get_embedding(source_type, source_id) do
    init()

    case :ets.lookup(@table, {source_type, source_id}) do
      [{_key, embedding}] -> {:ok, embedding}
      [] -> :not_found
    end
  end

  @doc """
  Search with MMR diversity applied to results.
  Enriches search results with their stored embeddings and delegates to MMR.select.
  """
  def search_with_mmr(query_embedding, k \\ 10, lambda \\ 0.7, opts \\ []) do
    candidates =
      search(query_embedding, k * 3, opts)
      |> Enum.map(fn {source_type, source_id, score} ->
        embedding =
          case get_embedding(source_type, source_id) do
            {:ok, emb} -> emb
            :not_found -> nil
          end

        %{source: source_type, id: source_id, score: score, embedding: embedding}
      end)

    Traitee.Memory.MMR.select(candidates, k, lambda)
  end

  @doc """
  Stores multiple embeddings at once.
  Takes a list of `{source_type, source_id, embedding}` tuples.
  """
  def bulk_store(items) when is_list(items) do
    init()

    Enum.each(items, fn {source_type, source_id, embedding} ->
      store(source_type, source_id, embedding)
    end)

    :ok
  end

  @doc """
  Returns the total number of vectors stored.
  """
  def count do
    init()
    :ets.info(@table, :size)
  end

  @doc """
  Returns stats about the vector index: total count and breakdown by source type.
  """
  def stats do
    init()

    entries = :ets.tab2list(@table)

    by_type =
      entries
      |> Enum.group_by(fn {{source_type, _id}, _emb} -> source_type end)
      |> Map.new(fn {type, items} -> {type, length(items)} end)

    %{total: length(entries), by_type: by_type}
  end

  @doc """
  Loads all embeddings from the database into the ETS index.
  Call during startup or after recovery.
  """
  def reindex do
    init()
    :ets.delete_all_objects(@table)

    load_summaries()
    load_facts()
    load_entities()

    :ok
  end

  # -- Private --

  # Stored vectors are unit-normalized, so cosine similarity is a plain
  # dot product — no per-row tensor construction or norm recomputation.
  defp dot_product(a, b) do
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end

  defp normalize(embedding) do
    floats = Enum.map(embedding, &(&1 * 1.0))
    norm = :math.sqrt(Enum.reduce(floats, 0.0, fn x, acc -> acc + x * x end))

    if norm == 0.0 do
      floats
    else
      Enum.map(floats, &(&1 / norm))
    end
  end

  defp to_float_list(%Nx.Tensor{} = t), do: Nx.to_flat_list(t)
  defp to_float_list(embedding) when is_list(embedding), do: embedding

  defp maybe_filter_type(entries, nil), do: entries

  defp maybe_filter_type(entries, type) do
    Enum.filter(entries, fn {{stype, _}, _} -> stype == type end)
  end

  defp load_summaries do
    import Ecto.Query

    Traitee.Memory.Schema.Summary
    |> where([s], not is_nil(s.embedding))
    |> Traitee.Repo.all()
    |> Enum.each(fn summary ->
      case decode_embedding(summary.embedding) do
        {:ok, emb} -> store(:summary, summary.id, emb)
        _ -> :ok
      end
    end)
  end

  defp load_facts do
    import Ecto.Query

    Traitee.Memory.Schema.Fact
    |> where([f], not is_nil(f.embedding))
    |> Traitee.Repo.all()
    |> Enum.each(fn fact ->
      case decode_embedding(fact.embedding) do
        {:ok, emb} -> store(:fact, fact.id, emb)
        _ -> :ok
      end
    end)
  end

  defp load_entities do
    import Ecto.Query

    Traitee.Memory.Schema.Entity
    |> where([e], not is_nil(e.embedding))
    |> Traitee.Repo.all()
    |> Enum.each(fn entity ->
      case decode_embedding(entity.embedding) do
        {:ok, emb} -> store(:entity, entity.id, emb)
        _ -> :ok
      end
    end)
  end

  defp decode_embedding(nil), do: {:error, nil}

  defp decode_embedding(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> {:error, :invalid_embedding}
  end
end
