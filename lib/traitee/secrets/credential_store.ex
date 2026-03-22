defmodule Traitee.Secrets.CredentialStore do
  @moduledoc "File-based credential storage in ~/.traitee/credentials/."

  @spec credentials_dir() :: String.t()
  def credentials_dir do
    Path.join(Traitee.data_dir(), "credentials")
  end

  @spec store(atom() | String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def store(provider, key, value) do
    provider = to_string(provider)
    dir = credentials_dir()
    File.mkdir_p!(dir)
    path = credential_path(provider)

    existing = load_file(path)
    data = Map.put(existing, key, value)

    case File.write(path, Jason.encode!(data, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load(atom() | String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def load(provider, key) do
    provider = to_string(provider)
    data = load_file(credential_path(provider))

    case Map.fetch(data, key) do
      {:ok, value} -> {:ok, value}
      :error -> :not_found
    end
  end

  @spec load_all(atom() | String.t()) :: map()
  def load_all(provider) do
    provider = to_string(provider)
    load_file(credential_path(provider))
  end

  @spec delete(atom() | String.t(), String.t()) :: :ok
  def delete(provider, key) do
    provider = to_string(provider)
    path = credential_path(provider)
    data = load_file(path) |> Map.delete(key)

    if data == %{} do
      File.rm(path)
    else
      File.write(path, Jason.encode!(data, pretty: true))
    end

    :ok
  end

  @spec list_providers() :: [String.t()]
  def list_providers do
    dir = credentials_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))

      {:error, _} ->
        []
    end
  end

  defp credential_path(provider) do
    Path.join(credentials_dir(), "#{provider}.json")
  end

  defp load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end
end
