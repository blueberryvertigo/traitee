defmodule TraiteeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :traitee

  @session_options [
    store: :cookie,
    key: "_traitee_key",
    signing_salt: "traitee_web",
    same_site: "Lax"
  ]

  socket "/ws", TraiteeWeb.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TraiteeWeb.Router
end
