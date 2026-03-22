defmodule Traitee.Browser.Supervisor do
  @moduledoc "Supervises the browser bridge process."
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      if browser_enabled?() do
        [Traitee.Browser.Bridge]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp browser_enabled? do
    config = Traitee.Config.get([:tools, :browser]) || %{}
    config[:enabled] != false
  end
end
