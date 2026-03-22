defmodule TraiteeWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def index(conn, _params) do
    json(conn, %{status: "ok", version: "0.1.0"})
  end
end
