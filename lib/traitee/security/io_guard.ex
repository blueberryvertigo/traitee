defmodule Traitee.Security.IOGuard do
  @moduledoc """
  Input/output filesystem guards — defense-in-depth layer independent of Sandbox.

  Provides two guard functions that operate on tool arguments and results:

  - `check_input/2` scans tool arguments for sensitive filesystem paths and
    dangerous commands before they reach the Sandbox. Catches bypass attempts
    even if the Sandbox module crashes or has a glob-matching bug.

  - `check_output/2` scans tool results for leaked secrets (private keys,
    API keys, credentials) and redacts them before they reach the LLM or user.

  Both use their own pattern lists, deliberately independent from
  `Traitee.Security.Filesystem`, so a failure in one module doesn't
  compromise the other.
  """

  alias Traitee.Security.Audit

  require Logger

  @sensitive_path_patterns [
    ~r{[\\/]\.ssh([\\/]|$)}i,
    ~r{[\\/]\.aws([\\/]|$)}i,
    ~r{[\\/]\.azure([\\/]|$)}i,
    ~r{[\\/]\.gcloud([\\/]|$)}i,
    ~r{[\\/]\.kube([\\/]|$)}i,
    ~r{[\\/]\.gnupg([\\/]|$)}i,
    ~r{[\\/]\.docker([\\/]|$)}i,
    ~r{[\\/]\.npmrc$}i,
    ~r{[\\/]\.netrc$}i,
    ~r{[\\/]\.pypirc$}i,
    ~r{[\\/]\.env$}i,
    ~r{[\\/]\.env\.[a-z]+$}i,
    ~r{[\\/]id_rsa}i,
    ~r{[\\/]id_ed25519}i,
    ~r{[\\/]id_ecdsa}i,
    ~r{[\\/]id_dsa}i,
    ~r{[\\/]master\.key$}i,
    ~r{[\\/]credentials\.json$}i,
    ~r{[\\/]service[_-]account[^\\/ ]*\.json$}i,
    ~r{[\\/]secrets\.(toml|ya?ml|json)$}i,
    ~r{[\\/]private[_-]?key[\\/]}i,
    ~r{[\\/]etc[\\/]shadow$}i,
    ~r{[\\/]etc[\\/]passwd$}i,
    ~r{\.pem$}i,
    ~r{\.p12$}i,
    ~r{\.pfx$}i,
    ~r{\.keystore$}i
  ]

  @dangerous_command_patterns [
    ~r{curl\s.+\|\s*(ba)?sh}i,
    ~r{wget\s.+\|\s*(ba)?sh}i,
    ~r{:\(\)\{.*\|.*&.*\}.*:}i,
    ~r{\bnc\s+(-[a-z]+\s+)*(-e|-l)}i,
    ~r{\bncat\s+--exec}i,
    ~r{\bsocat\b.+exec:}i,
    ~r{rm\s+-rf\s+/\s*$}i,
    ~r{dd\s+if=/dev/sd}i,
    ~r{chmod\s+\+s\s+}i,
    ~r{powershell\s+(-enc|-encodedcommand)}i,
    ~r{certutil\s+-urlcache}i,
    ~r{reg\s+add\s+\\\\?HKLM}i,
    ~r{net\s+user\s+\w+\s+\w+\s+/add}i
  ]

  @output_secret_patterns [
    {~r/-----BEGIN\s+(RSA\s+|EC\s+|DSA\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----/,
     "private_key"},
    {~r/-----BEGIN\s+CERTIFICATE-----/, "certificate"},
    {~r/ssh-(rsa|ed25519|ecdsa|dsa)\s+AAAA[A-Za-z0-9+\/]{40,}/, "ssh_public_key"},
    {~r/\bsk-[a-zA-Z0-9]{20,}\b/, "openai_api_key"},
    {~r/\bxai-[a-zA-Z0-9]{20,}\b/, "xai_api_key"},
    {~r/\bghp_[a-zA-Z0-9]{36,}\b/, "github_pat"},
    {~r/\bgho_[a-zA-Z0-9]{36,}\b/, "github_oauth"},
    {~r/\bglpat-[a-zA-Z0-9\-]{20,}\b/, "gitlab_pat"},
    {~r/\bAKIA[A-Z0-9]{16}\b/, "aws_access_key"},
    {~r/\bAIza[a-zA-Z0-9\-_]{35}\b/, "google_api_key"},
    {~r/\bey[a-zA-Z0-9]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\b/, "jwt_token"},
    {~r/\b[0-9a-f]{40}\b/, "hex_secret_40"},
    {~r/(password|passwd|pwd)\s*[:=]\s*["']?[^\s"']{8,}/i, "password_assignment"},
    {~r/(api[_-]?key|apikey|secret[_-]?key)\s*[:=]\s*["']?[^\s"']{8,}/i, "api_key_assignment"},
    {~r{(postgres|mysql|mongodb|redis)://[^:]+:[^@]+@}i, "database_url_with_password"}
  ]

  @path_arg_keys ["path", "file", "filename", "directory", "working_directory", "target"]
  @command_arg_keys ["command", "cmd", "script", "template"]

  @doc """
  Scans tool arguments for sensitive filesystem paths and dangerous commands.

  Returns `:ok` if clean, or `{:error, reason}` if a sensitive pattern is found.
  This check is independent of the Sandbox module — it's a second line of defense.
  """
  @spec check_input(String.t(), map()) :: :ok | {:error, String.t()}
  def check_input(tool_name, args) when is_map(args) do
    with :ok <- check_input_paths(tool_name, args),
         :ok <- check_input_commands(tool_name, args) do
      :ok
    end
  end

  def check_input(_tool_name, _args), do: :ok

  @doc """
  Scans tool output for leaked secrets and redacts them.

  Returns `{:clean, output}` if no secrets found, or
  `{:redacted, sanitized_output, findings}` with secrets replaced by
  `[REDACTED:<type>]` markers.
  """
  @spec check_output(String.t(), String.t()) ::
          {:clean, String.t()} | {:redacted, String.t(), [String.t()]}
  def check_output(tool_name, output) when is_binary(output) do
    findings = detect_secrets(output)

    if findings == [] do
      {:clean, output}
    else
      redacted = redact_secrets(output, findings)
      types = Enum.map(findings, fn {type, _} -> type end)

      Logger.warning(
        "[IOGuard] Redacted #{length(findings)} secret(s) in #{tool_name} output: #{Enum.join(types, ", ")}"
      )

      {:redacted, redacted, types}
    end
  end

  def check_output(_tool_name, output), do: {:clean, output}

  @doc """
  Wraps a tool execution in a fail-closed try/rescue block.

  If the function raises, returns `{:error, reason}` instead of crashing.
  """
  @spec safe_execute(String.t(), (-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, String.t()}
  def safe_execute(tool_name, fun) do
    fun.()
  rescue
    e ->
      reason = Exception.message(e)

      Logger.error("[IOGuard] Fail-closed in #{tool_name}: #{reason}")

      emit_audit(:io_guard_crash, %{
        tool: tool_name,
        decision: :deny,
        reason: "fail-closed: #{reason}"
      })

      {:error, "Security check failed — operation denied (fail-closed)"}
  end

  # --- Input checking ---

  defp check_input_paths(tool_name, args) do
    paths = extract_values(args, @path_arg_keys)
    commands = extract_values(args, @command_arg_keys)
    embedded_paths = Enum.flat_map(commands, &extract_paths_from_command/1)
    all_paths = paths ++ embedded_paths

    case Enum.find(all_paths, &sensitive_path?/1) do
      nil ->
        :ok

      path ->
        Logger.warning("[IOGuard] Input guard blocked sensitive path in #{tool_name}: #{path}")

        emit_audit(:io_guard_input, %{
          tool: tool_name,
          decision: :deny,
          reason: "sensitive path in arguments: #{path}"
        })

        {:error, "IO guard: access to sensitive path blocked — #{path}"}
    end
  end

  defp check_input_commands(tool_name, args) do
    commands = extract_values(args, @command_arg_keys)

    case Enum.find(commands, &dangerous_command?/1) do
      nil ->
        :ok

      cmd ->
        Logger.warning("[IOGuard] Input guard blocked dangerous command in #{tool_name}")

        emit_audit(:io_guard_input, %{
          tool: tool_name,
          decision: :deny,
          reason: "dangerous command pattern in arguments"
        })

        {:error, "IO guard: dangerous command blocked — #{String.slice(cmd, 0, 80)}"}
    end
  end

  defp extract_values(args, keys) do
    Enum.flat_map(keys, fn key ->
      case Map.get(args, key) do
        val when is_binary(val) and val != "" -> [val]
        _ -> []
      end
    end)
  end

  defp extract_paths_from_command(command) do
    Regex.scan(~r{(?:^|\s)((?:/|[A-Z]:\\)[^\s;|&"']+)}i, command)
    |> Enum.map(fn [_, path] -> path end)
  end

  defp sensitive_path?(path) do
    Enum.any?(@sensitive_path_patterns, &Regex.match?(&1, path))
  end

  defp dangerous_command?(command) do
    Enum.any?(@dangerous_command_patterns, &Regex.match?(&1, command))
  end

  # --- Output checking ---

  defp detect_secrets(output) do
    Enum.flat_map(@output_secret_patterns, fn {regex, type} ->
      case Regex.scan(regex, output) do
        [] -> []
        matches -> Enum.map(matches, fn [match | _] -> {type, match} end)
      end
    end)
    |> Enum.uniq_by(fn {type, _} -> type end)
  end

  defp redact_secrets(output, findings) do
    Enum.reduce(findings, output, fn {type, matched}, acc ->
      String.replace(acc, matched, "[REDACTED:#{type}]")
    end)
  end

  defp emit_audit(event_type, details) do
    Audit.record(event_type, details)
  rescue
    _ -> :ok
  end
end
