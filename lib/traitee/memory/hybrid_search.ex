defmodule Traitee.Memory.HybridSearch do
  @moduledoc "Hybrid vector + keyword search with configurable weights and MMR diversity."

  alias Traitee.LLM.Router
  alias Traitee.Memory.{LTM, MMR, MTM, QueryExpansion, TemporalDecay, Vector}

  @default_opts [
    limit: 10,
    vector_weight: 0.7,
    text_weight: 0.3,
    min_score: 0.0,
    source_types: nil,
    diversity: 0.3
  ]

  @doc """
  Hybrid search combining vector similarity with keyword matching.

  Options:
  - `:limit` - max results (default 10)
  - `:vector_weight` - weight for vector scores (default 0.7)
  - `:text_weight` - weight for keyword scores (default 0.3)
  - `:min_score` - minimum combined score threshold (default 0.0)
  - `:source_types` - filter to specific source types, e.g. `[:summary, :fact]`
  - `:diversity` - MMR diversity factor 0.0-1.0 (default 0.3, 0 = no diversity filtering)
  """
  def search(query, session_id, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    expanded_queries = QueryExpansion.expand(query)
    vector_results = expanded_vector_search(expanded_queries, opts)
    text_results = expanded_keyword_search(expanded_queries, session_id)

    merged =
      merge_results(vector_results, text_results, opts[:vector_weight], opts[:text_weight])

    merged
    |> maybe_filter_types(opts[:source_types])
    |> Enum.filter(&(&1.score >= opts[:min_score]))
    |> apply_diversity(opts[:limit], opts[:diversity])
    |> TemporalDecay.apply()
    |> Enum.take(opts[:limit])
  end

  defp expanded_vector_search(queries, opts) do
    queries
    |> Enum.flat_map(&vector_search(&1, opts))
    |> dedupe_max_score()
  end

  defp expanded_keyword_search(queries, session_id) do
    queries
    |> Enum.flat_map(&keyword_search(&1, session_id))
    |> dedupe_max_score()
  end

  defp dedupe_max_score(results) do
    results
    |> Enum.group_by(&{&1.source, &1.id})
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, & &1.score)
    end)
  end

  defp vector_search(query, opts) do
    case Router.embed([query]) do
      {:ok, [embedding]} ->
        Vector.search(embedding, opts[:limit] * 3, min_score: opts[:min_score])
        |> Enum.map(fn {source, id, score} ->
          %{source: source, id: id, score: score, content: nil, timestamp: nil, embedding: nil}
        end)

      _ ->
        []
    end
  end

  defp keyword_search(query, session_id) do
    summaries =
      MTM.search(session_id, query)
      |> Enum.map(fn s ->
        %{
          source: :summary,
          id: s.id,
          score: 1.0,
          content: s.content,
          timestamp: s.inserted_at,
          embedding: nil
        }
      end)

    facts =
      LTM.search_facts(query)
      |> Enum.map(fn f ->
        %{
          source: :fact,
          id: f.id,
          score: f.confidence || 1.0,
          content: f.content,
          timestamp: f.inserted_at,
          embedding: nil
        }
      end)

    entities =
      LTM.search_entities(query)
      |> Enum.map(fn e ->
        %{
          source: :entity,
          id: e.id,
          score: (e.mention_count || 1) / 10.0,
          content: "#{e.name}: #{e.description}",
          timestamp: e.updated_at,
          embedding: nil
        }
      end)

    summaries ++ facts ++ entities
  end

  defp merge_results(vector_results, text_results, vw, tw) do
    vector_normalized = normalize_scores(vector_results)
    text_normalized = normalize_scores(text_results)

    vector_map =
      Map.new(vector_normalized, fn r -> {{r.source, r.id}, r} end)

    text_map =
      Map.new(text_normalized, fn r -> {{r.source, r.id}, r} end)

    all_keys = MapSet.union(MapSet.new(Map.keys(vector_map)), MapSet.new(Map.keys(text_map)))

    Enum.map(all_keys, fn key ->
      v = Map.get(vector_map, key)
      t = Map.get(text_map, key)

      vs = if v, do: v.score, else: 0.0
      ts = if t, do: t.score, else: 0.0
      combined = vw * vs + tw * ts

      base = v || t
      %{base | score: combined}
    end)
  end

  defp normalize_scores([]), do: []

  defp normalize_scores(items) do
    max_score = items |> Enum.map(& &1.score) |> Enum.max()

    if max_score > 0 do
      Enum.map(items, fn item -> %{item | score: item.score / max_score} end)
    else
      items
    end
  end

  defp maybe_filter_types(results, nil), do: results

  defp maybe_filter_types(results, types) do
    Enum.filter(results, &(&1.source in types))
  end

  defp apply_diversity(results, limit, diversity) when diversity > 0 do
    MMR.select(results, limit, 1.0 - diversity)
  end

  defp apply_diversity(results, _limit, _diversity), do: results
end
