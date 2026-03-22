defmodule Traitee.Memory.MTM do
  @moduledoc """
  Mid-Term Memory -- conversation chunk summaries.

  Stores LLM-generated summaries of conversation chunks (~20 messages each).
  Each summary retains key facts, decisions, emotional tone, and open threads.
  Summaries are also embedded for semantic retrieval.
  """

  import Ecto.Query
  alias Traitee.Memory.Schema.Summary
  alias Traitee.Repo

  @doc """
  Creates a summary from a chunk of messages.
  Returns the inserted Summary struct.
  """
  def store_summary(session_id, content, attrs \\ %{}) do
    %Summary{}
    |> Summary.changeset(
      Map.merge(
        %{
          session_id: session_id,
          content: content,
          message_count: attrs[:message_count] || 0,
          message_range_start: attrs[:message_range_start],
          message_range_end: attrs[:message_range_end],
          key_topics: attrs[:key_topics] || [],
          embedding: attrs[:embedding]
        },
        %{}
      )
    )
    |> Repo.insert()
  end

  @doc """
  Returns all summaries for a session, ordered by creation time.
  """
  def get_summaries(session_id) do
    Summary
    |> where([s], s.session_id == ^session_id)
    |> order_by([s], asc: s.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns the N most recent summaries for a session.
  """
  def get_recent(session_id, n) do
    Summary
    |> where([s], s.session_id == ^session_id)
    |> order_by([s], desc: s.inserted_at)
    |> limit(^n)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Returns all summaries that have embeddings (for vector search).
  """
  def get_with_embeddings(session_id) do
    Summary
    |> where([s], s.session_id == ^session_id and not is_nil(s.embedding))
    |> Repo.all()
  end

  @doc """
  Returns the total number of summaries for a session.
  """
  def count(session_id) do
    Summary
    |> where([s], s.session_id == ^session_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Searches summaries by keyword in content.
  """
  def search(session_id, query) do
    pattern = "%#{query}%"

    Summary
    |> where([s], s.session_id == ^session_id and like(s.content, ^pattern))
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc """
  The prompt template used to generate summaries from message chunks.
  Returns both a summary and extracted entities/facts as JSON.
  """
  def summarization_prompt(messages) do
    formatted =
      Enum.map_join(messages, "\n", fn msg -> "#{msg.role}: #{msg.content}" end)

    """
    Analyze the following conversation segment and produce a JSON response with exactly two keys:

    1. "summary": A concise 1-2 paragraph summary that captures:
       - Key decisions made
       - Important facts discussed
       - Open questions or threads
       - Emotional tone and context

    2. "entities": An array of extracted entities, each with:
       - "name": The entity name
       - "type": One of "person", "project", "concept", "preference", "place", "organization", "tool", "other"
       - "facts": Array of factual statements about this entity from the conversation
       - "relations": Array of {target, relation_type, description} tuples

    Conversation:
    #{formatted}

    Respond with valid JSON only, no markdown formatting.
    """
  end
end
