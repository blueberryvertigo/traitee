defmodule TraiteeWeb.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :v1_auth do
    plug :require_api_token
  end

  scope "/api", TraiteeWeb do
    pipe_through :api

    get "/webhook/:channel", WebhookController, :verify
    post "/webhook/:channel", WebhookController, :handle
    get "/health", HealthController, :index
  end

  scope "/v1", TraiteeWeb do
    pipe_through [:api, :v1_auth]

    post "/chat/completions", OpenAIProxyController, :chat_completions
    post "/embeddings", OpenAIProxyController, :embeddings
    get "/models", OpenAIProxyController, :models
  end

  # Fail-closed: /v1 spends LLM credits, so an unconfigured token rejects all requests.
  defp require_api_token(conn, _opts) do
    case Traitee.Config.get([:web, :api_token]) do
      token when is_binary(token) and token != "" ->
        check_api_token(conn, token)

      _ ->
        unauthorized(
          conn,
          "API access disabled: set web.api_token in the Traitee config to enable /v1"
        )
    end
  end

  defp check_api_token(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> provided] ->
        if Plug.Crypto.secure_compare(provided, token) do
          conn
        else
          unauthorized(conn, "Invalid API token")
        end

      _ ->
        unauthorized(conn, "Missing Authorization: Bearer <token> header")
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      error: %{message: message, type: "authentication_error", code: "unauthorized"}
    })
    |> halt()
  end
end
