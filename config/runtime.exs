import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :traitee, TraiteeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end

# LLM API keys
if api_key = System.get_env("OPENAI_API_KEY") do
  config :traitee, :openai_api_key, api_key
end

if api_key = System.get_env("ANTHROPIC_API_KEY") do
  config :traitee, :anthropic_api_key, api_key
end

if api_key = System.get_env("XAI_API_KEY") do
  config :traitee, :xai_api_key, api_key
end

# Channel tokens
if token = System.get_env("DISCORD_BOT_TOKEN") do
  config :traitee, :discord_bot_token, token
end

if token = System.get_env("TELEGRAM_BOT_TOKEN") do
  config :traitee, :telegram_bot_token, token
end

if token = System.get_env("WHATSAPP_TOKEN") do
  config :traitee, :whatsapp_token, token
end

# User config file path
toml_path = System.get_env("TRAITEE_CONFIG") || Path.expand("~/.traitee/config.toml")

if File.exists?(toml_path) do
  config :traitee, :config_path, toml_path
end
