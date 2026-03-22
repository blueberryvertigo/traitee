defmodule Traitee.Repo.Migrations.CreateMemoryTables do
  use Ecto.Migration

  def change do
    # -- Sessions --
    create table(:sessions) do
      add :session_id, :string, null: false
      add :channel, :string
      add :status, :string, default: "active"
      add :message_count, :integer, default: 0
      add :last_activity, :utc_datetime
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:sessions, [:session_id])

    # -- Messages (raw archive) --
    create table(:messages) do
      add :session_id, :string, null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :channel, :string
      add :token_count, :integer
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:session_id])
    create index(:messages, [:session_id, :inserted_at])

    # -- Summaries (MTM) --
    create table(:summaries) do
      add :session_id, :string, null: false
      add :content, :text, null: false
      add :message_range_start, :integer
      add :message_range_end, :integer
      add :message_count, :integer
      add :embedding, :binary
      add :key_topics, {:array, :string}, default: []
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:summaries, [:session_id])

    # -- Entities (LTM knowledge graph nodes) --
    create table(:entities) do
      add :name, :string, null: false
      add :entity_type, :string, null: false
      add :description, :text
      add :embedding, :binary
      add :mention_count, :integer, default: 1
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:entities, [:name, :entity_type], name: :entities_name_type_index)

    # -- Relations (LTM knowledge graph edges) --
    create table(:relations) do
      add :source_entity_id, references(:entities, on_delete: :delete_all), null: false
      add :target_entity_id, references(:entities, on_delete: :delete_all), null: false
      add :relation_type, :string, null: false
      add :description, :text
      add :strength, :float, default: 1.0
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:relations, [:source_entity_id])
    create index(:relations, [:target_entity_id])

    # -- Facts (LTM extracted knowledge) --
    create table(:facts) do
      add :entity_id, references(:entities, on_delete: :nilify_all)
      add :content, :text, null: false
      add :fact_type, :string, null: false
      add :confidence, :float, default: 1.0
      add :source_summary_id, references(:summaries, on_delete: :nilify_all)
      add :embedding, :binary
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:facts, [:entity_id])
    create index(:facts, [:fact_type])
  end
end
