import Config

config :traitee, TraiteeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: String.duplicate("dev_secret_", 8)

config :logger, level: :info

config :traitee, Traitee.Repo, log: false
