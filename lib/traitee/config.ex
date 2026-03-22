defmodule Traitee.Config do
  @moduledoc """
  Configuration system for Traitee.

  Loads config from multiple sources in priority order:
  1. Environment variables (highest priority)
  2. TOML config file (~/.traitee/config.toml)
  3. Application config (config/*.exs -- lowest priority)

  The TOML file supports `env:VAR_NAME` syntax to pull values from
  environment variables at runtime, keeping secrets out of config files.
  """

  @default_config %{
    agent: %{
      model: "anthropic/claude-opus-4.6",
      fallback_model: "openai/gpt-5.4",
      system_prompt:
        "You are Traitee, a personal AI assistant platform. Be concise, helpful, and personable."
    },
    memory: %{
      stm_capacity: 50,
      mtm_chunk_size: 20,
      embedding_model: "openai/text-embedding-3-small"
    },
    channels: %{
      discord: %{enabled: false, token: nil, dm_policy: "pairing"},
      telegram: %{enabled: false, token: nil, dm_policy: "pairing"},
      whatsapp: %{
        enabled: false,
        token: nil,
        phone_number_id: nil,
        verify_token: nil,
        dm_policy: "pairing"
      },
      signal: %{enabled: false, cli_path: "signal-cli", phone_number: nil, dm_policy: "pairing"},
      webchat: %{enabled: true, dm_policy: "pairing"}
    },
    tools: %{
      bash: %{enabled: true, sandbox: true, working_dir: nil},
      file: %{enabled: true, allowed_paths: []},
      web_search: %{enabled: false, provider: nil, api_key: nil},
      browser: %{enabled: true, headless: true, timeout: 30_000},
      cron: %{enabled: true}
    },
    evolution: %{
      mode: "propose",
      learnings_dir: ".learnings"
    },
    security: %{
      enabled: true,
      owner_id: nil,
      channel_ids: %{},
      cognitive: %{
        enabled: true,
        reminder_interval: 8,
        canary_enabled: true,
        output_guard: "redact",
        judge: %{
          enabled: true,
          model: "xai/grok-4-1-fast-non-reasoning",
          timeout_ms: 3_000,
          min_message_length: 10
        }
      }
    },
    gateway: %{
      port: 4000,
      host: "127.0.0.1"
    }
  }

  @doc """
  Loads and merges configuration from all sources.
  Call once at application startup; result is cached in persistent_term.
  """
  def load! do
    config =
      @default_config
      |> deep_merge(load_toml())
      |> deep_merge(load_env_overrides())

    :persistent_term.put({__MODULE__, :config}, config)
    config
  end

  @doc """
  Retrieves a config value by key path. Returns nil if not found.

  ## Examples

      Traitee.Config.get([:agent, :model])
      #=> "anthropic/claude-opus-4.6"

      Traitee.Config.get([:channels, :discord, :token])
      #=> "bot_token_here"
  """
  def get(key_path) when is_list(key_path) do
    config = get_config()
    get_in_map(config, key_path)
  end

  def get(key) when is_atom(key) do
    get([key])
  end

  @doc """
  Returns the full config map.
  """
  def all do
    get_config()
  end

  @doc """
  Returns the default configuration.
  """
  def defaults, do: @default_config

  @doc """
  Returns the owner's platform-specific ID for a given channel.
  Falls back to the primary `owner_id` if no channel-specific ID is configured.
  """
  @spec owner_id_for_channel(atom()) :: String.t() | nil
  def owner_id_for_channel(channel_type) when is_atom(channel_type) do
    case get([:security, :channel_ids, channel_type]) do
      nil -> get([:security, :owner_id])
      "" -> get([:security, :owner_id])
      id -> id
    end
  end

  @doc """
  Checks whether a sender_id belongs to the owner on the given channel.
  Compares against the channel-specific ID first, then the primary owner_id.
  """
  @spec sender_is_owner?(String.t() | integer(), atom()) :: boolean()
  def sender_is_owner?(sender_id, channel_type) do
    sid = to_string(sender_id)

    channel_owner = owner_id_for_channel(channel_type)
    primary_owner = get([:security, :owner_id])

    cond do
      is_nil(channel_owner) and is_nil(primary_owner) -> false
      channel_owner && sid == to_string(channel_owner) -> true
      primary_owner && sid == to_string(primary_owner) -> true
      true -> false
    end
  end

  # -- Private --

  defp get_config do
    :persistent_term.get({__MODULE__, :config})
  rescue
    ArgumentError -> load!()
  end

  defp load_toml do
    case Application.get_env(:traitee, :config_path) do
      nil ->
        path = Traitee.config_path()
        if File.exists?(path), do: parse_toml(path), else: %{}

      path ->
        if File.exists?(path), do: parse_toml(path), else: %{}
    end
  end

  defp parse_toml(path) do
    case Toml.decode_file(path) do
      {:ok, parsed} ->
        parsed
        |> atomize_keys()
        |> resolve_env_values()

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to parse TOML config at #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp load_env_overrides do
    discord_token = resolve_credential(:discord, :discord_bot_token, "bot_token")
    telegram_token = resolve_credential(:telegram, :telegram_bot_token, "bot_token")
    whatsapp_token = resolve_credential(:whatsapp, :whatsapp_token, "bot_token")

    %{}
    |> maybe_put([:agent, :model], System.get_env("TRAITEE_MODEL"))
    |> maybe_put([:channels, :discord, :token], discord_token)
    |> maybe_put([:channels, :discord, :enabled], !is_nil(discord_token))
    |> maybe_put([:channels, :telegram, :token], telegram_token)
    |> maybe_put([:channels, :telegram, :enabled], !is_nil(telegram_token))
    |> maybe_put([:channels, :whatsapp, :token], whatsapp_token)
  end

  defp resolve_credential(provider, app_env_key, credential_key) do
    Application.get_env(:traitee, app_env_key) ||
      case Traitee.Secrets.CredentialStore.load(provider, credential_key) do
        {:ok, value} -> value
        :not_found -> nil
      end
  end

  @doc false
  def resolve_env_values(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, resolve_env_values(v)} end)
  end

  def resolve_env_values("env:" <> var_name) do
    System.get_env(String.trim(var_name))
  end

  def resolve_env_values(list) when is_list(list) do
    Enum.map(list, &resolve_env_values/1)
  end

  def resolve_env_values(other), do: other

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end

  defp deep_merge(_base, override), do: override

  defp get_in_map(value, []), do: value

  defp get_in_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value -> get_in_map(value, rest)
    end
  end

  defp get_in_map(_other, _keys), do: nil

  defp maybe_put(map, _path, nil), do: map
  defp maybe_put(map, _path, false), do: map

  defp maybe_put(map, path, value) do
    put_in_nested(map, path, value)
  end

  defp put_in_nested(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_in_nested(map, [key | rest], value) do
    sub = Map.get(map, key, %{})
    Map.put(map, key, put_in_nested(sub, rest, value))
  end
end
