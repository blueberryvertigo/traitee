defmodule Traitee.Repo do
  use Ecto.Repo,
    otp_app: :traitee,
    adapter: Ecto.Adapters.SQLite3
end
