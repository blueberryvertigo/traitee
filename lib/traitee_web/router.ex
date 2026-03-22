defmodule TraiteeWeb.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", TraiteeWeb do
    pipe_through :api

    post "/webhook/:channel", WebhookController, :handle
    get "/health", HealthController, :index
  end

  scope "/v1", TraiteeWeb do
    pipe_through :api

    post "/chat/completions", OpenAIProxyController, :chat_completions
    post "/embeddings", OpenAIProxyController, :embeddings
    get "/models", OpenAIProxyController, :models
  end
end
