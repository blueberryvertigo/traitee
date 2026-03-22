defmodule Traitee.Repo.Migrations.CreateCronTables do
  use Ecto.Migration

  def change do
    create table(:cron_jobs) do
      add :name, :string, null: false
      add :job_type, :string, null: false
      add :schedule, :string, null: false
      add :payload, :map, default: %{}
      add :channel, :string
      add :target, :string
      add :enabled, :boolean, default: true
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime
      add :run_count, :integer, default: 0
      add :consecutive_errors, :integer, default: 0
      add :last_error, :text
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:cron_jobs, [:name])
  end
end
