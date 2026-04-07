defmodule Traitee.Cognition.Schema do
  @moduledoc "Ecto schemas for the cognition subsystem."

  defmodule UserInterest do
    use Ecto.Schema
    import Ecto.Changeset

    schema "user_interests" do
      field :owner_id, :string
      field :topic, :string
      field :enthusiasm_score, :float, default: 0.5
      field :frequency, :integer, default: 1
      field :depth, :string, default: "shallow"
      field :first_seen, :utc_datetime
      field :last_seen, :utc_datetime
      field :trend, :string, default: "stable"
      field :evidence, :map, default: %{}
      field :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    def changeset(interest, attrs) do
      interest
      |> cast(attrs, [
        :owner_id,
        :topic,
        :enthusiasm_score,
        :frequency,
        :depth,
        :first_seen,
        :last_seen,
        :trend,
        :evidence,
        :metadata
      ])
      |> validate_required([:owner_id, :topic])
    end
  end

  defmodule WorkshopProject do
    use Ecto.Schema
    import Ecto.Changeset

    schema "workshop_projects" do
      field :name, :string
      field :description, :string
      field :project_type, :string
      field :status, :string, default: "ideating"
      field :interest_source, :string
      field :artifacts, :map, default: %{}
      field :token_cost, :integer, default: 0
      field :owner_id, :string
      field :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    @valid_statuses ~w(ideating researching building ready presented accepted rejected)
    @valid_types ~w(tool skill code research)

    def changeset(project, attrs) do
      project
      |> cast(attrs, [
        :name,
        :description,
        :project_type,
        :status,
        :interest_source,
        :artifacts,
        :token_cost,
        :owner_id,
        :metadata
      ])
      |> validate_required([:name, :project_type, :owner_id])
      |> validate_inclusion(:status, @valid_statuses)
      |> validate_inclusion(:project_type, @valid_types)
      |> unique_constraint(:name)
    end
  end
end
