defmodule Traitee.DataCase do
  @moduledoc """
  Test case for modules that require database access.
  Sets up Ecto sandbox for transactional isolation.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Traitee.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Traitee.DataCase
    end
  end

  setup tags do
    Traitee.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Traitee.Repo, shared: !tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
