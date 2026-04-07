defmodule Traitee.Cognition.Supervisor do
  @moduledoc """
  Supervisor for the cognitive architecture processes.
  Only starts children when cognition is enabled in config.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      if cognition_enabled?() do
        [
          Traitee.Cognition.UserModel,
          Traitee.Cognition.Dream,
          Traitee.Cognition.Workshop,
          Traitee.Cognition.QualityControl,
          Traitee.Cognition.Metacognition
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp cognition_enabled? do
    Traitee.Config.get([:cognition, :enabled]) != false
  rescue
    _ -> true
  end
end
