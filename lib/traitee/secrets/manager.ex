defmodule Traitee.Secrets.Manager do
  @moduledoc "Secrets management with resolution, audit, and credential matrix."

  alias Traitee.Secrets.CredentialStore

  @credential_matrix %{
    openai: [:api_key],
    anthropic: [:api_key],
    claude_subscription: [:access_token, :refresh_token],
    ollama: [],
    discord: [:bot_token],
    telegram: [:bot_token],
    whatsapp: [:token, :phone_number_id, :verify_token],
    signal: [:phone_number],
    web_search: [:api_key]
  }

  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve("env:" <> var_name) do
    case System.get_env(String.trim(var_name)) do
      nil -> {:error, :not_found}
      val -> {:ok, val}
    end
  end

  def resolve("file:" <> ref) do
    case String.split(ref, ":", parts: 3) do
      [provider, key] ->
        case CredentialStore.load(provider, key) do
          {:ok, _} = ok -> ok
          :not_found -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def resolve("config:" <> path_str) do
    keys = path_str |> String.split(".") |> Enum.map(&String.to_existing_atom/1)

    case Traitee.Config.get(keys) do
      nil -> {:error, :not_found}
      val -> {:ok, to_string(val)}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  def resolve(_), do: {:error, :not_found}

  @spec credential_matrix() :: map()
  def credential_matrix, do: @credential_matrix

  @spec audit() :: map()
  def audit do
    Map.new(@credential_matrix, fn {provider, keys} ->
      status =
        if keys == [] do
          :configured
        else
          if Enum.all?(keys, &secret_present?(provider, &1)) do
            :configured
          else
            :missing
          end
        end

      {provider, status}
    end)
  end

  @spec store_credential(atom() | String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def store_credential(provider, key, value) do
    CredentialStore.store(provider, key, value)
  end

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    secrets = collect_known_secrets()

    Enum.reduce(secrets, text, fn secret, acc ->
      if String.length(secret) >= 4 do
        String.replace(acc, secret, "***")
      else
        acc
      end
    end)
  end

  def redact(other), do: other

  defp secret_present?(provider, key) do
    env_key =
      "#{provider |> to_string() |> String.upcase()}_#{key |> to_string() |> String.upcase()}"

    System.get_env(env_key) != nil or
      CredentialStore.load(provider, to_string(key)) != :not_found or
      config_present?(provider, key)
  end

  defp config_present?(provider, key) do
    case Traitee.Config.get([:channels, provider, key]) do
      nil -> Traitee.Config.get([:tools, provider, key]) != nil
      _ -> true
    end
  end

  defp collect_known_secrets do
    env_secrets =
      for {provider, keys} <- @credential_matrix,
          key <- keys,
          env_key =
            "#{provider |> to_string() |> String.upcase()}_#{key |> to_string() |> String.upcase()}",
          val = System.get_env(env_key),
          val != nil,
          do: val

    file_secrets =
      for provider <- CredentialStore.list_providers(),
          {_key, val} <- CredentialStore.load_all(provider),
          is_binary(val),
          do: val

    Enum.uniq(env_secrets ++ file_secrets)
  end
end
