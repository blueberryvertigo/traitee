defmodule Traitee.Repo.Migrations.CreateCognitionTables do
  use Ecto.Migration

  def change do
    create table(:user_interests) do
      add :owner_id, :string, null: false
      add :topic, :string, null: false
      add :enthusiasm_score, :float, default: 0.5
      add :frequency, :integer, default: 1
      add :depth, :string, default: "shallow"
      add :first_seen, :utc_datetime
      add :last_seen, :utc_datetime
      add :trend, :string, default: "stable"
      add :evidence, :map, default: %{}
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_interests, [:owner_id, :topic])
    create index(:user_interests, [:owner_id])

    create table(:workshop_projects) do
      add :name, :string, null: false
      add :description, :text
      add :project_type, :string, null: false
      add :status, :string, default: "ideating"
      add :interest_source, :string
      add :artifacts, :map, default: %{}
      add :token_cost, :integer, default: 0
      add :owner_id, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workshop_projects, [:name])
    create index(:workshop_projects, [:owner_id])
    create index(:workshop_projects, [:status])
  end
end
