defmodule Traitee.Memory.LTM do
  @moduledoc """
  Long-Term Memory -- knowledge graph stored in SQLite.

  Manages entities (people, projects, concepts, preferences), their relationships,
  and extracted facts. This is the persistent "brain" that enables cross-session
  recall like "What did I say about project X last week?"
  """

  import Ecto.Query
  alias Traitee.Memory.Schema.{Entity, Fact, Relation}
  alias Traitee.Memory.Vector
  alias Traitee.Repo

  @default_search_limit 25

  # -- Entities --

  @doc """
  Creates or updates an entity. If an entity with the same name and type exists,
  increments its mention count.
  """
  def upsert_entity(name, type, description \\ nil) do
    case get_entity_by_name(name, type) do
      nil -> insert_entity(name, type, description)
      existing -> bump_entity(existing, description)
    end
  end

  defp insert_entity(name, type, description) do
    %Entity{}
    |> Entity.changeset(%{name: name, entity_type: type, description: description})
    |> Repo.insert()
    |> case do
      {:ok, entity} ->
        {:ok, entity}

      {:error, changeset} ->
        # Read-then-insert is non-atomic: a concurrent writer may have created
        # the entity between our lookup and insert. Re-fetch and update it.
        case get_entity_by_name(name, type) do
          nil -> {:error, changeset}
          existing -> bump_entity(existing, description)
        end
    end
  end

  defp bump_entity(existing, description) do
    existing
    |> Entity.changeset(%{
      mention_count: (existing.mention_count || 0) + 1,
      description: description || existing.description
    })
    |> Repo.update()
  end

  @doc """
  Finds an entity by name and type.
  """
  def get_entity_by_name(name, type) do
    Entity
    |> where([e], e.name == ^name and e.entity_type == ^type)
    |> Repo.one()
  end

  @doc """
  Searches entities by name pattern. Limited to `limit` rows (default 25).
  """
  def search_entities(query, limit \\ @default_search_limit) do
    pattern = "%#{query}%"

    Entity
    |> where([e], like(e.name, ^pattern) or like(e.description, ^pattern))
    |> order_by([e], desc: e.mention_count)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the top N most mentioned entities.
  """
  def top_entities(n \\ 20) do
    Entity
    |> order_by([e], desc: e.mention_count)
    |> limit(^n)
    |> Repo.all()
  end

  @doc """
  Returns all entities.
  """
  def all_entities do
    Repo.all(Entity)
  end

  @doc """
  Returns entities of a given entity_type, most recently updated first.
  """
  def entities_by_type(type, limit \\ 20) do
    Entity
    |> where([e], e.entity_type == ^type)
    |> order_by([e], desc: e.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # -- Relations --

  @doc """
  Creates a relation between two entities.
  """
  def add_relation(source_id, target_id, relation_type, description \\ nil) do
    case get_relation(source_id, target_id, relation_type) do
      nil ->
        %Relation{}
        |> Relation.changeset(%{
          source_entity_id: source_id,
          target_entity_id: target_id,
          relation_type: relation_type,
          description: description
        })
        |> Repo.insert()

      existing ->
        existing
        |> Relation.changeset(%{
          strength: (existing.strength || 1.0) + 0.5,
          description: description || existing.description
        })
        |> Repo.update()
    end
  end

  @doc """
  Gets relations for an entity (both outgoing and incoming).
  """
  def get_relations(entity_id) do
    outgoing =
      Relation
      |> where([r], r.source_entity_id == ^entity_id)
      |> Repo.all()

    incoming =
      Relation
      |> where([r], r.target_entity_id == ^entity_id)
      |> Repo.all()

    # Batch-load all linked entities in one query instead of one Repo.get
    # per relation.
    other_ids =
      Enum.map(outgoing, & &1.target_entity_id) ++ Enum.map(incoming, & &1.source_entity_id)

    entities = load_entities_by_ids(Enum.uniq(other_ids))

    Enum.map(outgoing, fn r ->
      %{direction: :outgoing, relation: r, entity: Map.get(entities, r.target_entity_id)}
    end) ++
      Enum.map(incoming, fn r ->
        %{direction: :incoming, relation: r, entity: Map.get(entities, r.source_entity_id)}
      end)
  end

  defp load_entities_by_ids([]), do: %{}

  defp load_entities_by_ids(ids) do
    Entity
    |> where([e], e.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp get_relation(source_id, target_id, type) do
    Relation
    |> where(
      [r],
      r.source_entity_id == ^source_id and
        r.target_entity_id == ^target_id and
        r.relation_type == ^type
    )
    |> Repo.one()
  end

  # -- Facts --

  @doc """
  Adds a fact linked to an entity.
  """
  def add_fact(entity_id, content, fact_type, source_summary_id \\ nil, opts \\ []) do
    confidence = Keyword.get(opts, :confidence, 1.0)

    %Fact{}
    |> Fact.changeset(%{
      entity_id: entity_id,
      content: content,
      fact_type: fact_type,
      source_summary_id: source_summary_id,
      confidence: confidence,
      metadata: Keyword.get(opts, :metadata, %{})
    })
    |> Repo.insert()
  end

  @doc """
  Gets all facts for an entity.
  """
  def get_facts(entity_id) do
    Fact
    |> where([f], f.entity_id == ^entity_id)
    |> order_by([f], desc: f.inserted_at)
    |> Repo.all()
  end

  @doc """
  Searches facts by content pattern. Limited to `limit` rows (default 25).
  """
  def search_facts(query, limit \\ @default_search_limit) do
    pattern = "%#{query}%"

    Fact
    |> where([f], like(f.content, ^pattern))
    |> order_by([f], desc: f.confidence)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns all facts with embeddings for vector search.
  """
  def get_facts_with_embeddings do
    Fact
    |> where([f], not is_nil(f.embedding))
    |> Repo.all()
  end

  @doc """
  Reassigns all facts from one entity to another. Used by the Dream
  consolidation cycle to merge duplicates without losing data. Avoids the
  old copy+orphan pattern that left the duplicate in place and grew facts
  exponentially on every cycle.
  """
  def reassign_facts(from_entity_id, to_entity_id) do
    Fact
    |> where([f], f.entity_id == ^from_entity_id)
    |> Repo.update_all(set: [entity_id: to_entity_id])
  end

  @doc """
  Reassigns all relations (both source and target) from one entity to another.
  """
  def reassign_relations(from_entity_id, to_entity_id) do
    Relation
    |> where([r], r.source_entity_id == ^from_entity_id)
    |> Repo.update_all(set: [source_entity_id: to_entity_id])

    Relation
    |> where([r], r.target_entity_id == ^from_entity_id)
    |> Repo.update_all(set: [target_entity_id: to_entity_id])
  end

  @doc """
  Deletes an entity by id. Caller is responsible for reassigning or
  deleting its facts/relations first, otherwise they'll orphan.
  """
  def delete_entity(entity_id) do
    result =
      Entity
      |> where([e], e.id == ^entity_id)
      |> Repo.delete_all()

    # Drop the stale vector so semantic search can't surface a deleted
    # entity. Reassigned facts keep their own ids, so their vectors stay
    # valid.
    Vector.delete(:entity, entity_id)
    result
  end

  @doc """
  Best-effort metadata write on an entity. Silently skips if the schema
  lacks a metadata column so older DBs don't break.
  """
  def set_entity_metadata(entity_id, metadata) when is_map(metadata) do
    case Repo.get(Entity, entity_id) do
      nil ->
        :ok

      entity ->
        if Map.has_key?(entity, :metadata) do
          entity
          |> Entity.changeset(%{metadata: metadata})
          |> Repo.update()
          |> case do
            {:ok, _} -> :ok
            {:error, _} -> :ok
          end
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  end

  # -- Graph Queries --

  @doc """
  Gets the full subgraph around an entity: the entity itself, its relations,
  and facts. Useful for injecting entity context into prompts.
  """
  def entity_context(entity_id) do
    entity = Repo.get(Entity, entity_id)

    if entity do
      relations = get_relations(entity_id)
      facts = get_facts(entity_id)

      %{
        entity: entity,
        relations: relations,
        facts: facts
      }
    else
      nil
    end
  end

  @doc """
  Formats entity context as a string suitable for injection into an LLM prompt.
  """
  def format_context(nil), do: ""

  def format_context(%{entity: entity, relations: relations, facts: facts}) do
    lines = ["[#{entity.entity_type}] #{entity.name}: #{entity.description || ""}"]

    fact_lines =
      facts
      |> Enum.take(10)
      |> Enum.map(fn f -> "  - #{f.content}" end)

    rel_lines =
      relations
      |> Enum.take(10)
      |> Enum.map(fn r ->
        other = r.entity
        dir = if r.direction == :outgoing, do: "->", else: "<-"
        "  #{dir} #{r.relation.relation_type} #{other && other.name}"
      end)

    Enum.join(lines ++ fact_lines ++ rel_lines, "\n")
  end

  @doc """
  Returns memory statistics for the LTM.
  """
  def stats do
    %{
      entities: Repo.aggregate(Entity, :count, :id),
      relations: Repo.aggregate(Relation, :count, :id),
      facts: Repo.aggregate(Fact, :count, :id)
    }
  end
end
