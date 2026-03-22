import Config

config :traitee, TraiteeWeb.Endpoint,
  url: [host: "localhost", port: 443, scheme: "https"],
  check_origin: false

config :logger, level: :info
