defmodule Traitee.Memory.Vector do
  @moduledoc """
  Vector index for semantic retrieval across all memory tiers.

  Stores embeddings in an ETS table and performs cosine similarity
  search using Nx tensors. For datasets under 100k vectors, this
  in-memory approach is fast enough without external dependencies.
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
  """
  def store(source_type, source_id, embedding) when is_list(embedding) do
    key = {source_type, source_id}
    :ets.insert(@table, {key, embedding})
    :ok
  end

  def store(_source_type, _source_id, nil), do: :ok

  @doc """
  Removes an embedding.
  """
  def delete(source_type, source_id) do
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

    query_tensor = to_tensor(query_embedding)

    results =
      @table
      |> :ets.tab2list()
      |> maybe_filter_type(filter_type)
      |> Enum.map(fn {{stype, sid}, embedding} ->
        score = cosine_similarity(query_tensor, to_tensor(embedding))
        {stype, sid, score}
      end)
      |> Enum.filter(fn {_, _, score} -> score >= min_score end)
      |> Enum.sort_by(fn {_, _, score} -> score end, :desc)
      |> Enum.take(k)

    results
  end

  @doc """
  Retrieves a stored embedding for a given source type and ID.
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

    :ok
  end

  # -- Private --

  defp cosine_similarity(a, b) do
    dot = Nx.dot(a, b) |> Nx.to_number()
    norm_a = Nx.LinAlg.norm(a) |> Nx.to_number()
    norm_b = Nx.LinAlg.norm(b) |> Nx.to_number()

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  defp to_tensor(embedding) when is_list(embedding) do
    Nx.tensor(embedding, type: :f32)
  end

  defp to_tensor(%Nx.Tensor{} = t), do: t

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

  defp decode_embedding(nil), do: {:error, nil}

  defp decode_embedding(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    _ -> {:error, :invalid_embedding}
  end
end
