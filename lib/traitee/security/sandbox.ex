defmodule Traitee.Security.Sandbox do
  @moduledoc """
  OS-level sandbox policy for tool execution.

  Validates file paths against allowlists and blocklists, filters dangerous
  shell commands, and scrubs secrets from child process environments.
  Inspired by NanoClaw's mount-security model, adapted for Traitee's
  single-process architecture.
  """

  require Logger

  @blocked_path_patterns [
    ".ssh",
    ".gnupg",
    ".gpg",
    ".aws",
    ".azure",
    ".gcloud",
    ".kube",
    ".docker",
    ".npmrc",
    ".pypirc",
    ".netrc",
    "credentials",
    "id_rsa",
    "id_ed25519",
    "id_ecdsa",
    "id_dsa",
    "private_key",
    ".secret",
    ".pem",
    ".p12",
    ".pfx",
    ".keystore"
  ]

  @blocked_filenames [
    ".env",
    ".env.local",
    ".env.production",
    ".env.staging",
    "secrets.toml",
    "secrets.yml",
    "secrets.yaml",
    "secrets.json",
    "credentials.json",
    "service-account.json",
    "master.key",
    "shadow",
    "passwd"
  ]

  @dangerous_command_patterns [
    ~r/\bcurl\b.*\|\s*(ba)?sh\b/i,
    ~r/\bwget\b.*\|\s*(ba)?sh\b/i,
    ~r/\beval\b.*\$\(/,
    ~r/\bnc\b\s+-[el]/i,
    ~r/\bncat\b/i,
    ~r/\bsocat\b/i,
    ~r/\bpython\S*\s+-c\s+.*\bsocket\b/i,
    ~r/\bchmod\b.*\+s\b/,
    ~r/\bmkfifo\b/,
    ~r/\bdd\b\s+if=\/dev\//,
    ~r/\brm\s+(-[rRf]+\s+)*(\/|~\/?\s*$)/,
    ~r/\b>\s*\/dev\/sd[a-z]/,
    ~r/\b(fork|:)\s*\(\)\s*\{/,
    ~r/:\(\)\{\s*:\|:\s*&\s*\};:/
  ]

  @secret_env_patterns [
    ~r/KEY/i,
    ~r/SECRET/i,
    ~r/TOKEN/i,
    ~r/PASSWORD/i,
    ~r/CREDENTIAL/i,
    ~r/AUTH/i
  ]

  @safe_env_allowlist [
    "PATH",
    "HOME",
    "USER",
    "SHELL",
    "LANG",
    "LC_ALL",
    "TERM",
    "TZ",
    "TMPDIR",
    "TEMP",
    "TMP",
    "HOSTNAME",
    "PWD",
    "MIX_ENV",
    "PORT",
    "PHX_HOST",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME",
    "SYSTEMROOT",
    "COMSPEC",
    "PATHEXT",
    "PROGRAMFILES",
    "WINDIR",
    "APPDATA",
    "LOCALAPPDATA",
    "USERPROFILE"
  ]

  # -- Path validation --

  @doc """
  Checks whether a file path is safe to access.
  Resolves symlinks, checks against blocked patterns/filenames,
  and enforces the allowed_paths allowlist when configured.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_path(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_path(path, opts \\ []) do
    operation = Keyword.get(opts, :operation, :read)
    resolved = resolve_path(path)

    with :ok <- check_blocked_patterns(resolved),
         :ok <- check_blocked_filenames(resolved),
         :ok <- check_allowed_paths(resolved, operation) do
      :ok
    end
  end

  @doc "Returns the list of blocked path patterns."
  @spec blocked_path_patterns() :: [String.t()]
  def blocked_path_patterns, do: @blocked_path_patterns

  @doc "Returns the list of blocked filenames."
  @spec blocked_filenames() :: [String.t()]
  def blocked_filenames, do: @blocked_filenames

  # -- Command validation --

  @doc """
  Checks whether a shell command is safe to execute.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_command(String.t()) :: :ok | {:error, String.t()}
  def check_command(command) do
    case Enum.find(@dangerous_command_patterns, &Regex.match?(&1, command)) do
      nil ->
        :ok

      pattern ->
        Logger.warning("[Sandbox] Blocked dangerous command: #{inspect(command)}")
        {:error, "Command blocked by sandbox policy: matches #{inspect(Regex.source(pattern))}"}
    end
  end

  # -- Environment scrubbing --

  @doc """
  Returns a scrubbed environment variable list suitable for child processes.
  Strips any variable whose name matches secret patterns, unless it appears
  in the safe allowlist.
  """
  @spec scrubbed_env() :: [{String.t(), String.t()}]
  def scrubbed_env do
    System.get_env()
    |> Enum.filter(fn {key, _val} -> safe_env_var?(key) end)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  @doc "Checks whether sandbox mode is enabled for bash tools."
  @spec sandbox_enabled?() :: boolean()
  def sandbox_enabled? do
    Traitee.Config.get([:tools, :bash, :sandbox]) == true
  end

  @doc "Returns the configured working directory for sandboxed bash, or a safe default."
  @spec sandbox_working_dir() :: String.t()
  def sandbox_working_dir do
    configured = Traitee.Config.get([:tools, :bash, :working_dir])

    if is_binary(configured) and configured != "" do
      Path.expand(configured)
    else
      Path.join(Traitee.data_dir(), "sandbox")
    end
  end

  # -- Private --

  defp resolve_path(path) do
    expanded = Path.expand(path)

    case File.read_link(expanded) do
      {:ok, target} ->
        target
        |> Path.expand(Path.dirname(expanded))
        |> resolve_path()

      {:error, _} ->
        expanded
    end
  end

  defp check_blocked_patterns(resolved) do
    parts = Path.split(resolved)

    case Enum.find(@blocked_path_patterns, fn pattern ->
           Enum.any?(parts, &(String.downcase(&1) == String.downcase(pattern)))
         end) do
      nil -> :ok
      pattern -> {:error, "Path blocked: contains sensitive directory \"#{pattern}\""}
    end
  end

  defp check_blocked_filenames(resolved) do
    basename = Path.basename(resolved) |> String.downcase()

    case Enum.find(@blocked_filenames, &(String.downcase(&1) == basename)) do
      nil -> :ok
      name -> {:error, "Path blocked: sensitive filename \"#{name}\""}
    end
  end

  defp check_allowed_paths(resolved, operation) do
    allowed = Traitee.Config.get([:tools, :file, :allowed_paths]) || []

    if allowed == [] do
      :ok
    else
      data_dir = Traitee.data_dir() |> Path.expand()
      effective = Enum.map(allowed, &Path.expand/1) ++ [data_dir]

      if Enum.any?(effective, &path_under?(&1, resolved)) do
        :ok
      else
        action = if operation == :read, do: "read", else: "write"
        {:error, "Path not in allowed_paths for #{action}: #{resolved}"}
      end
    end
  end

  defp path_under?(root, path) do
    normalized_root = String.replace(root, "\\", "/") |> ensure_trailing_slash()
    normalized_path = String.replace(path, "\\", "/")

    String.starts_with?(normalized_path, normalized_root) or
      normalized_path == String.trim_trailing(normalized_root, "/")
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp safe_env_var?(key) do
    upper = String.upcase(key)

    if Enum.any?(@safe_env_allowlist, &(String.upcase(&1) == upper)) do
      true
    else
      not Enum.any?(@secret_env_patterns, &Regex.match?(&1, key))
    end
  end
end
