defmodule Traitee.Memory.Schema do
  @moduledoc """
  Ecto schemas for the hierarchical memory system.
  """

  defmodule Message do
    use Ecto.Schema
    import Ecto.Changeset

    schema "messages" do
      field :session_id, :string
      field :role, :string
      field :content, :string
      field :channel, :string
      field :token_count, :integer
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    def changeset(message, attrs) do
      message
      |> cast(attrs, [:session_id, :role, :content, :channel, :token_count, :metadata])
      |> validate_required([:session_id, :role, :content])
      |> validate_inclusion(:role, ["system", "user", "assistant", "tool"])
    end
  end

  defmodule Summary do
    use Ecto.Schema
    import Ecto.Changeset

    schema "summaries" do
      field :session_id, :string
      field :content, :string
      field :message_range_start, :integer
      field :message_range_end, :integer
      field :message_count, :integer
      field :embedding, :binary
      field :key_topics, {:array, :string}, default: []
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    def changeset(summary, attrs) do
      summary
      |> cast(attrs, [
        :session_id,
        :content,
        :message_range_start,
        :message_range_end,
        :message_count,
        :embedding,
        :key_topics,
        :metadata
      ])
      |> validate_required([:session_id, :content, :message_count])
    end
  end

  defmodule Entity do
    use Ecto.Schema
    import Ecto.Changeset

    schema "entities" do
      field :name, :string
      field :entity_type, :string
      field :description, :string
      field :embedding, :binary
      field :mention_count, :integer, default: 1
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    def changeset(entity, attrs) do
      entity
      |> cast(attrs, [:name, :entity_type, :description, :embedding, :mention_count, :metadata])
      |> validate_required([:name, :entity_type])
      |> unique_constraint(:name, name: :entities_name_type_index)
    end
  end

  defmodule Relation do
    use Ecto.Schema
    import Ecto.Changeset

    schema "relations" do
      field :source_entity_id, :integer
      field :target_entity_id, :integer
      field :relation_type, :string
      field :description, :string
      field :strength, :float, default: 1.0
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    def changeset(relation, attrs) do
      relation
      |> cast(attrs, [
        :source_entity_id,
        :target_entity_id,
        :relation_type,
        :description,
        :strength,
        :metadata
      ])
      |> validate_required([:source_entity_id, :target_entity_id, :relation_type])
    end
  end

  defmodule Fact do
    use Ecto.Schema
    import Ecto.Changeset

    schema "facts" do
      field :entity_id, :integer
      field :content, :string
      field :fact_type, :string
      field :confidence, :float, default: 1.0
      field :source_summary_id, :integer
      field :embedding, :binary
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    def changeset(fact, attrs) do
      fact
      |> cast(attrs, [
        :entity_id,
        :content,
        :fact_type,
        :confidence,
        :source_summary_id,
        :embedding,
        :metadata
      ])
      |> validate_required([:content, :fact_type])
    end
  end

  defmodule Session do
    use Ecto.Schema
    import Ecto.Changeset

    schema "sessions" do
      field :session_id, :string
      field :channel, :string
      field :status, :string, default: "active"
      field :message_count, :integer, default: 0
      field :last_activity, :utc_datetime
      field :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    def changeset(session, attrs) do
      session
      |> cast(attrs, [:session_id, :channel, :status, :message_count, :last_activity, :metadata])
      |> validate_required([:session_id])
      |> unique_constraint(:session_id)
    end
  end
end
