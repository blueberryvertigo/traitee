defmodule Traitee.Tools.Memory do
  @moduledoc """
  Memory tool -- lets the LLM explicitly store and recall facts, entities,
  and information across sessions.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Memory.LTM
  alias Traitee.Context.Continuity

  @impl true
  def name, do: "memory"

  @impl true
  def description do
    """
    Store and recall information across conversations. Use 'remember' to save \
    facts about the user or important details. Use 'recall' to search memories. \
    Use 'list_entities' to see what you know about.\
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["remember", "recall", "list_entities"],
          "description" =>
            "Action: remember (store a fact), recall (search memories), list_entities (see known entities)"
        },
        "entity" => %{
          "type" => "string",
          "description" =>
            "Entity name (person, project, concept) to associate the fact with. Required for 'remember'."
        },
        "entity_type" => %{
          "type" => "string",
          "enum" => ["person", "project", "concept", "preference", "place", "other"],
          "description" => "Type of entity (default: 'other')"
        },
        "fact" => %{
          "type" => "string",
          "description" => "The fact to remember. Be specific and clear."
        },
        "query" => %{
          "type" => "string",
          "description" => "Search query for recall"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "remember", "entity" => entity, "fact" => fact} = args)
      when is_binary(entity) and is_binary(fact) do
    entity_type = args["entity_type"] || "other"

    case LTM.upsert_entity(entity, entity_type) do
      {:ok, ent} ->
        case LTM.add_fact(ent.id, fact, "explicit") do
          {:ok, _} -> {:ok, "Remembered: #{entity} — #{fact}"}
          {:error, cs} -> {:error, "Failed to store fact: #{inspect(cs.errors)}"}
        end

      {:error, cs} ->
        {:error, "Failed to create entity: #{inspect(cs.errors)}"}
    end
  end

  def execute(%{"action" => "remember"}) do
    {:error, "Missing required parameters: entity, fact"}
  end

  def execute(%{"action" => "recall", "query" => query}) when is_binary(query) do
    results = Continuity.recall(query)
    formatted = Continuity.format_recall(results)

    if formatted == "" do
      {:ok, "No memories found for \"#{query}\"."}
    else
      {:ok, formatted}
    end
  end

  def execute(%{"action" => "recall"}) do
    {:error, "Missing required parameter: query"}
  end

  def execute(%{"action" => "list_entities"}) do
    entities = LTM.top_entities(20)

    if entities == [] do
      {:ok, "No entities stored yet."}
    else
      lines =
        Enum.map(entities, fn e ->
          desc = if e.description, do: " — #{e.description}", else: ""
          "  #{e.name} (#{e.entity_type}, #{e.mention_count || 1} mentions)#{desc}"
        end)

      {:ok, "Known entities:\n#{Enum.join(lines, "\n")}"}
    end
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Supported: remember, recall, list_entities"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}
end
