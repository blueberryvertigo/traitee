defmodule Traitee.Cron.Schema do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "cron_jobs" do
    field :name, :string
    field :job_type, :string
    field :schedule, :string
    field :payload, :map, default: %{}
    field :channel, :string
    field :target, :string
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :next_run_at, :utc_datetime
    field :run_count, :integer, default: 0
    field :consecutive_errors, :integer, default: 0
    field :last_error, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :name,
      :job_type,
      :schedule,
      :payload,
      :channel,
      :target,
      :enabled,
      :last_run_at,
      :next_run_at,
      :run_count,
      :consecutive_errors,
      :last_error,
      :metadata
    ])
    |> validate_required([:name, :job_type, :schedule])
    |> validate_inclusion(:job_type, ["at", "every", "cron"])
    |> unique_constraint(:name)
  end
end
