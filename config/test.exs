import Config

config :traitee, Traitee.Repo,
  database: Path.expand("~/.traitee/traitee_test.db"),
  pool: Ecto.Adapters.SQL.Sandbox

config :traitee, TraiteeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test_secret_", 8),
  server: false

config :logger, level: :warning
