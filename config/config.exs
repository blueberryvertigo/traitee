import Config

config :traitee,
  ecto_repos: [Traitee.Repo]

config :traitee, Traitee.Repo, database: Path.expand("~/.traitee/traitee.db")

config :traitee, TraiteeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: TraiteeWeb.ErrorJSON], layout: false],
  pubsub_server: Traitee.PubSub,
  live_view: [signing_salt: "traitee_lv"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
