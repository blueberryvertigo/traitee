defmodule Traitee.Context.Continuity do
  @moduledoc """
  Cross-session continuity and topic threading.

  Enables features like:
  - "Remember when I asked about X?" across sessions
  - Detecting topic shifts within a conversation
  - Automatic session recovery on restart
  """

  alias Traitee.Memory.{LTM, MTM, Vector, Schema}
  alias Traitee.LLM.Router

  @doc """
  Searches across all memory tiers for information matching a query.
  Returns a structured result with matches from STM, MTM, and LTM.
  """
  def recall(query, opts \\ []) do
    session_id = opts[:session_id]
    limit = opts[:limit] || 10

    ltm_results = search_ltm(query)
    mtm_results = search_mtm(query, session_id)
    vector_results = search_vectors(query, limit)

    %{
      facts: ltm_results.facts,
      entities: ltm_results.entities,
      summaries: mtm_results,
      semantic_matches: vector_results,
      query: query
    }
  end

  @doc """
  Formats recall results into a string suitable for LLM context injection.
  """
  def format_recall(results) do
    parts = []

    parts =
      if results.entities != [] do
        entity_text =
          results.entities
          |> Enum.take(3)
          |> Enum.map(fn e ->
            "#{e.name} (#{e.entity_type}): #{e.description || "no description"}"
          end)
          |> Enum.join("\n")

        parts ++ ["Entities:\n#{entity_text}"]
      else
        parts
      end

    parts =
      if results.facts != [] do
        fact_text =
          results.facts
          |> Enum.take(5)
          |> Enum.map(fn f -> "- #{f.content}" end)
          |> Enum.join("\n")

        parts ++ ["Facts:\n#{fact_text}"]
      else
        parts
      end

    parts =
      if results.summaries != [] do
        summary_text =
          results.summaries
          |> Enum.take(3)
          |> Enum.map(fn s -> s.content end)
          |> Enum.join("\n---\n")

        parts ++ ["Past conversations:\n#{summary_text}"]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  @doc """
  Detects if the current message represents a topic shift from previous messages.
  Returns `:same_topic`, `:related`, or `:new_topic`.
  """
  def detect_topic_shift(current_message, recent_messages) when is_list(recent_messages) do
    if recent_messages == [] do
      :new_topic
    else
      recent_text =
        recent_messages
        |> Enum.take(-5)
        |> Enum.map(fn msg -> msg[:content] || msg.content || "" end)
        |> Enum.join(" ")

      current_words = extract_keywords(current_message)
      recent_words = extract_keywords(recent_text)

      overlap = MapSet.intersection(current_words, recent_words) |> MapSet.size()
      current_size = MapSet.size(current_words)

      cond do
        current_size == 0 -> :same_topic
        overlap / max(current_size, 1) > 0.3 -> :same_topic
        overlap > 0 -> :related
        true -> :new_topic
      end
    end
  end

  @doc """
  Recovers a session's state from persistent storage after a restart.
  Returns the data needed to reinitialize the session.
  """
  def recover_session(session_id) do
    import Ecto.Query

    session_record =
      Schema.Session
      |> where([s], s.session_id == ^session_id)
      |> Traitee.Repo.one()

    recent_messages =
      Schema.Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], desc: m.inserted_at)
      |> limit(50)
      |> Traitee.Repo.all()
      |> Enum.reverse()

    summaries = MTM.get_recent(session_id, 5)

    %{
      session: session_record,
      messages: recent_messages,
      summaries: summaries,
      exists: session_record != nil
    }
  end

  @doc """
  Persists or updates a session record.
  """
  def persist_session(session_id, attrs \\ %{}) do
    import Ecto.Query

    case Traitee.Repo.one(from s in Schema.Session, where: s.session_id == ^session_id) do
      nil ->
        %Schema.Session{}
        |> Schema.Session.changeset(
          Map.merge(%{session_id: session_id, last_activity: DateTime.utc_now()}, attrs)
        )
        |> Traitee.Repo.insert()

      existing ->
        existing
        |> Schema.Session.changeset(Map.merge(%{last_activity: DateTime.utc_now()}, attrs))
        |> Traitee.Repo.update()
    end
  end

  # -- Private --

  defp search_ltm(query) do
    terms = [query | split_terms(query)] |> Enum.uniq()

    entities =
      terms
      |> Enum.flat_map(&LTM.search_entities/1)
      |> Enum.uniq_by(& &1.id)

    facts =
      entities
      |> Enum.flat_map(fn e -> LTM.get_facts(e.id) end)
      |> Enum.uniq_by(& &1.id)

    direct_facts =
      terms
      |> Enum.flat_map(&LTM.search_facts/1)
      |> Enum.uniq_by(& &1.id)

    %{
      entities: entities,
      facts: Enum.uniq_by(facts ++ direct_facts, & &1.id)
    }
  end

  defp split_terms(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
  end

  defp search_mtm(_query, nil) do
    []
  end

  defp search_mtm(query, session_id) do
    MTM.search(session_id, query)
  end

  defp search_vectors(query, limit) do
    case Router.embed([query]) do
      {:ok, [query_emb]} ->
        Vector.search(query_emb, limit, min_score: 0.25)

      _ ->
        []
    end
  end

  defp extract_keywords(text) do
    stop_words = MapSet.new(~w(the a an is are was were be been being have has had
      do does did will would shall should may might can could
      i me my we our you your he she it they them their
      this that these those in on at by for with from to of and or but))

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn w -> MapSet.member?(stop_words, w) or String.length(w) < 3 end)
    |> MapSet.new()
  end
end
