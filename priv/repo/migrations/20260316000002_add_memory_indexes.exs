defmodule Traitee.Repo.Migrations.AddMemoryIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:messages, [:inserted_at])
    create_if_not_exists index(:summaries, [:inserted_at])
    create_if_not_exists index(:facts, [:inserted_at])
    create_if_not_exists index(:sessions, [:last_activity])
    create_if_not_exists index(:entities, [:updated_at])
  end
end
