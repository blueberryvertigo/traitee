defmodule Traitee.Memory.LTM do
  @moduledoc """
  Long-Term Memory -- knowledge graph stored in SQLite.

  Manages entities (people, projects, concepts, preferences), their relationships,
  and extracted facts. This is the persistent "brain" that enables cross-session
  recall like "What did I say about project X last week?"
  """

  import Ecto.Query
  alias Traitee.Repo
  alias Traitee.Memory.Schema.{Entity, Relation, Fact}

  # -- Entities --

  @doc """
  Creates or updates an entity. If an entity with the same name and type exists,
  increments its mention count.
  """
  def upsert_entity(name, type, description \\ nil) do
    case get_entity_by_name(name, type) do
      nil ->
        %Entity{}
        |> Entity.changeset(%{name: name, entity_type: type, description: description})
        |> Repo.insert()

      existing ->
        existing
        |> Entity.changeset(%{
          mention_count: (existing.mention_count || 0) + 1,
          description: description || existing.description
        })
        |> Repo.update()
    end
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
  Searches entities by name pattern.
  """
  def search_entities(query) do
    pattern = "%#{query}%"

    Entity
    |> where([e], like(e.name, ^pattern) or like(e.description, ^pattern))
    |> order_by([e], desc: e.mention_count)
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
      |> Enum.map(fn r ->
        target = Repo.get(Entity, r.target_entity_id)
        %{direction: :outgoing, relation: r, entity: target}
      end)

    incoming =
      Relation
      |> where([r], r.target_entity_id == ^entity_id)
      |> Repo.all()
      |> Enum.map(fn r ->
        source = Repo.get(Entity, r.source_entity_id)
        %{direction: :incoming, relation: r, entity: source}
      end)

    outgoing ++ incoming
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
  def add_fact(entity_id, content, fact_type, source_summary_id \\ nil) do
    %Fact{}
    |> Fact.changeset(%{
      entity_id: entity_id,
      content: content,
      fact_type: fact_type,
      source_summary_id: source_summary_id
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
  Searches facts by content pattern.
  """
  def search_facts(query) do
    pattern = "%#{query}%"

    Fact
    |> where([f], like(f.content, ^pattern))
    |> order_by([f], desc: f.confidence)
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
