defmodule Traitee.Security.Filesystem do
  @moduledoc """
  Filesystem access policy engine with per-path read/write/deny rules.

  Evaluates every filesystem access against a layered policy:
    1. Hardcoded deny list (sensitive paths that are never accessible)
    2. User-configured deny patterns (glob-based)
    3. User-configured allow patterns with per-path permissions (read/write)
    4. Default policy (deny-all in sandbox mode, allow-read otherwise)

  Policies are loaded from config at `[:security, :filesystem]` and cached
  in an ETS table for lock-free concurrent reads. Hot-reload via PubSub
  picks up config changes without restart.

  All access decisions are emitted to `Traitee.Security.Audit` when available.
  """

  require Logger

  @table :traitee_fs_policy
  @operations [:read, :write, :list, :exists, :exec]

  @hardcoded_deny_patterns [
    "**/.ssh/**",
    "**/.gnupg/**",
    "**/.gpg/**",
    "**/.aws/**",
    "**/.azure/**",
    "**/.gcloud/**",
    "**/.kube/**",
    "**/.docker/**",
    "**/.npmrc",
    "**/.pypirc",
    "**/.netrc",
    "**/id_rsa*",
    "**/id_ed25519*",
    "**/id_ecdsa*",
    "**/id_dsa*",
    "**/private_key/**",
    "**/.secret/**",
    "**/*.pem",
    "**/*.p12",
    "**/*.pfx",
    "**/*.keystore",
    "**/.env",
    "**/.env.*",
    "**/secrets.toml",
    "**/secrets.yml",
    "**/secrets.yaml",
    "**/secrets.json",
    "**/credentials.json",
    "**/service-account.json",
    "**/master.key",
    "**/shadow",
    "**/passwd",
    "**/etc/shadow",
    "**/etc/passwd",
    "C:/Windows/**",
    "**/windows/system32/**",
    "C:/ProgramData/Microsoft/**",
    "**/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/**",
    "**/.config/systemd/**",
    "/proc/**",
    "**/proc/**",
    "/sys/**",
    "**/sys/**",
    "/dev/**",
    "**/dev/sd*",
    "**/dev/nvme*",
    "**/dev/hd*"
  ]

  # Paths inside the Traitee data directory that tools are NEVER allowed to
  # write to (or read, for credentials). These protect the agent's own
  # configuration, identity files, persisted tool registry, pairing state,
  # database, and skill/workspace files that feed the system prompt.
  # Paths are data-dir-relative, matched against the normalized tail.
  @data_dir_protected_writes [
    "config.toml",
    "approved_senders.json",
    "pending_pairings.json",
    "dynamic_tools.json",
    "traitee.db",
    "traitee.db-journal",
    "traitee.db-wal",
    "traitee.db-shm",
    "traitee_test.db",
    "credentials/**",
    "workspace/SOUL.md",
    "workspace/AGENTS.md",
    "workspace/TOOLS.md",
    "workspace/BOOT.md",
    "workspace/skills/**"
  ]

  @data_dir_protected_reads [
    "credentials/**",
    "config.toml"
  ]

  @hardcoded_deny_commands [
    # Pipe-to-shell: handle /bin/sh, /usr/bin/bash, zsh, ksh, dash, python, node, tee-then-run.
    ~r/\b(?:curl|wget|fetch|iwr|Invoke-WebRequest)\b[^\n]*\|\s*(?:\S*\/)?(?:ba|z|k|da|a)?sh\b/i,
    ~r/\b(?:curl|wget|fetch|iwr|Invoke-WebRequest)\b[^\n]*\|\s*(?:python|perl|ruby|node|php|tee)\b/i,
    # Process substitution: bash <(curl …), sh <(…)
    ~r/\b(?:ba|z|k|da|a)?sh\b\s+<\(\s*(?:curl|wget|fetch)/i,
    # PowerShell download-and-exec
    ~r/(?:iex|Invoke-Expression)\s*\(\s*(?:irm|Invoke-RestMethod|New-Object\s+[^)]*WebClient)/i,
    # Reverse / listening shells and tunnels
    ~r/\beval\b[^\n]*\$\(/,
    ~r/\bnc\b\s+-[el]/i,
    ~r/\bncat\b/i,
    ~r/\bsocat\b/i,
    ~r/\bpython\S*\s+-c\s+[^\n]*\bsocket\b/i,
    # SUID/SGID manipulation
    ~r/\bchmod\b[^\n]*\+s\b/,
    ~r/\bmkfifo\b/,
    ~r/\bdd\b\s+if=\/dev\//,
    # Recursive deletion: catches -rf, --recursive --force, --no-preserve-root, Windows variants.
    ~r/\brm\b[^\n]*(?:-[a-zA-Z]*r[a-zA-Z]*\b|--recursive|--no-preserve-root)/i,
    ~r/\bRemove-Item\b[^\n]*-Recurse/i,
    ~r/\brmdir\b[^\n]*\/s/i,
    ~r/\bdel\b[^\n]*\/s/i,
    ~r/\bfind\b[^\n]*-delete\b/i,
    # Disk-write to raw devices
    ~r/\b>\s*\/dev\/(?:sd[a-z]|nvme|hd[a-z]|mmcblk)/,
    # Fork bombs
    ~r/:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/,
    # PowerShell / pwsh evasion
    ~r/\b(?:powershell|pwsh|powershell_ise)\b[^\n]*(?:-e\b|-en\b|-enc\b|-encodedcommand|-nop\b|-noprofile|-w(?:\s|$)|-windowstyle\s+hidden|-executionpolicy\s+bypass)/i,
    # Windows system/persistence abuse
    ~r/\bcertutil\b[^\n]*-urlcache/i,
    ~r/\bbitsadmin\b[^\n]*\/transfer/i,
    ~r/\bmshta\b[^\n]*https?:/i,
    ~r/\bregsvr32\b[^\n]*\/i:/i,
    ~r/\breg\b\s+(?:add|delete)\b[^\n]*HKLM/i,
    ~r/\bnet\b\s+user\b[^\n]*\/add/i,
    ~r/\btakeown\b[^\n]*\/f\b/i,
    ~r/\bicacls\b[^\n]*\/grant[^\n]*everyone/i,
    ~r/\b(?:format|diskpart|bcdedit|cipher\s+\/w|sdelete)\b/i,
    ~r/\bmklink\b[^\n]*\/[jd]/i,
    # Container / sandbox escape attempts from the bash tool
    ~r/\b(?:docker|podman|nerdctl|containerd|runc|ctr|kubectl|crictl)\b/i,
    ~r/\bchroot\b/i,
    ~r/\b(?:pivot_root|unshare|nsenter)\b/i,
    ~r/\bmount\b(?!.*--help)/i,
    # Privilege escalation helpers
    ~r/\b(?:sudo|pkexec|doas|runas)\b/i,
    # Command-chain privilege escalation via setcap
    ~r/\bsetcap\b/i
  ]

  # Environment variables — strict ALLOWLIST. Everything not listed is dropped.
  # Deliberately minimal: we do not leak any secret-bearing or persistence-
  # granting vars (AWS_PROFILE, DATABASE_URL, SSH_AUTH_SOCK, KUBECONFIG, etc.).
  @safe_env_allowlist [
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "TZ",
    "HOSTNAME",
    "MIX_ENV",
    "XDG_DATA_HOME",
    "XDG_CONFIG_HOME"
  ]

  # Additional vars allowed only when NOT running in sandbox mode (host shell
  # needs these to resolve binaries; inside a container they are unnecessary
  # and can aid discovery/persistence).
  @host_only_env_allowlist [
    "HOME",
    "USER",
    "SHELL",
    "TMPDIR",
    "TEMP",
    "TMP",
    "PWD",
    "SYSTEMROOT",
    "COMSPEC",
    "PATHEXT",
    "WINDIR",
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "PROGRAMFILES"
  ]

  # -- Initialization --

  @doc "Initialize the filesystem policy ETS table and load policies from config."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    reload_policies()
    :ok
  end

  @doc "Reload policies from config into ETS. Called on config hot-reload."
  def reload_policies do
    config = load_config()
    :ets.insert(@table, {:policy, config})
    Logger.debug("[Filesystem] Policies reloaded: #{inspect(summarize_policy(config))}")
    :ok
  end

  # -- Path access control --

  @doc """
  Check whether a path is accessible for the given operation.

  Returns `:ok` or `{:error, reason}`. Emits an audit event regardless of outcome.

  ## Options
    - `:operation` - `:read`, `:write`, `:list`, `:exists`, or `:exec` (default: `:read`)
    - `:tool` - name of the requesting tool (for audit)
    - `:session_id` - session making the request (for audit)
  """
  @spec check_path(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_path(path, opts \\ []) do
    operation = Keyword.get(opts, :operation, :read)
    policy = current_policy()

    # Reject unsafe Windows/path forms BEFORE any expansion/resolution.
    # Catches UNC (`\\server\…`), long-path prefix (`\\?\…`), device namespaces
    # (`\\.\…`), NUL-byte injections, and 8.3-short-name markers.
    result =
      with :ok <- reject_unsafe_path_forms(path),
           {:ok, resolved} <- safe_resolve_path(path),
           :ok <- check_hardcoded_deny(resolved),
           :ok <- check_configured_deny(resolved, policy),
           :ok <- check_data_dir_policy(resolved, operation),
           :ok <- check_configured_allow(resolved, operation, policy),
           :ok <- check_default_policy(resolved, operation, policy) do
        :ok
      end

    {resolved_for_audit, result_for_audit} =
      case result do
        {:ok, _resolved} -> {path, :ok}
        :ok -> {path, :ok}
        {:error, _} = err -> {path, err}
      end

    emit_audit(:path_access, %{
      path: resolved_for_audit,
      original_path: path,
      operation: operation,
      decision: if(result_for_audit == :ok, do: :allow, else: :deny),
      reason: format_decision_reason(result_for_audit),
      tool: Keyword.get(opts, :tool, :unknown),
      session_id: Keyword.get(opts, :session_id)
    })

    result_for_audit
  end

  @doc """
  Check whether a shell command is safe to execute.

  Validates against both hardcoded and configured command deny patterns.
  Also extracts file paths from the command and validates them.
  """
  @spec check_command(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_command(command, opts \\ []) do
    policy = current_policy()

    result =
      with :ok <- check_hardcoded_command(command),
           :ok <- check_configured_command_deny(command, policy),
           :ok <- check_command_path_refs(command, opts) do
        :ok
      end

    emit_audit(:command_check, %{
      command: truncate_command(command),
      decision: if(result == :ok, do: :allow, else: :deny),
      reason: format_decision_reason(result),
      tool: Keyword.get(opts, :tool, :bash),
      session_id: Keyword.get(opts, :session_id)
    })

    result
  end

  @doc """
  Returns a scrubbed environment variable list safe for child processes.

  Uses a strict ALLOWLIST: only explicitly-safe vars are forwarded. Inside
  sandbox mode, the allowlist is further narrowed to drop host-discovery
  variables (`USERPROFILE`, `APPDATA`, `HOME`, etc.).
  """
  @spec scrubbed_env() :: [{charlist(), charlist()}]
  def scrubbed_env do
    allow = effective_env_allowlist()

    System.get_env()
    |> Enum.filter(fn {key, _val} ->
      upper = String.upcase(key)
      MapSet.member?(allow, upper)
    end)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp effective_env_allowlist do
    base = Enum.map(@safe_env_allowlist, &String.upcase/1)

    extra =
      if sandbox_enabled?() do
        []
      else
        Enum.map(@host_only_env_allowlist, &String.upcase/1)
      end

    MapSet.new(base ++ extra)
  rescue
    _ -> MapSet.new(Enum.map(@safe_env_allowlist, &String.upcase/1))
  end

  # -- Policy queries --

  @doc "Returns whether sandbox mode is globally enabled."
  @spec sandbox_enabled?() :: boolean()
  def sandbox_enabled? do
    policy = current_policy()
    policy.sandbox_mode
  end

  @doc "Returns the sandbox working directory."
  @spec sandbox_working_dir() :: String.t()
  def sandbox_working_dir do
    policy = current_policy()

    if is_binary(policy.working_dir) and policy.working_dir != "" do
      Path.expand(policy.working_dir)
    else
      Path.join(Traitee.data_dir(), "sandbox")
    end
  end

  @doc "Returns the current policy for inspection/audit."
  @spec current_policy() :: map()
  def current_policy do
    case :ets.whereis(@table) do
      :undefined ->
        load_config()

      _ ->
        case :ets.lookup(@table, :policy) do
          [{:policy, policy}] -> policy
          [] -> load_config()
        end
    end
  end

  @doc "Returns the default deny policy (what happens when no rules match)."
  @spec default_policy() :: :deny | :read_only | :allow
  def default_policy do
    current_policy().default_policy
  end

  @doc "Returns list of all configured allow rules for inspection."
  @spec allow_rules() :: [map()]
  def allow_rules do
    current_policy().allow_rules
  end

  @doc "Returns list of all configured deny rules for inspection."
  @spec deny_rules() :: [map()]
  def deny_rules do
    current_policy().deny_rules
  end

  @doc "Returns the hardcoded deny patterns."
  @spec hardcoded_deny_patterns() :: [String.t()]
  def hardcoded_deny_patterns, do: @hardcoded_deny_patterns

  @doc "Returns the hardcoded deny command patterns."
  @spec hardcoded_deny_commands() :: [Regex.t()]
  def hardcoded_deny_commands, do: @hardcoded_deny_commands

  @doc """
  Summarizes the current filesystem security posture.
  Used by the security audit mix task.
  """
  @spec posture_summary() :: map()
  def posture_summary do
    policy = current_policy()

    %{
      sandbox_mode: policy.sandbox_mode,
      default_policy: policy.default_policy,
      docker_enabled: policy.docker_enabled,
      allow_rules_count: length(policy.allow_rules),
      deny_rules_count: length(policy.deny_rules),
      command_deny_count: length(policy.command_deny_patterns),
      hardcoded_deny_count: length(@hardcoded_deny_patterns),
      hardcoded_command_deny_count: length(@hardcoded_deny_commands),
      working_dir: sandbox_working_dir(),
      exec_gate_enabled: policy.exec_gate_enabled,
      audit_enabled: policy.audit_enabled,
      allow_rules: policy.allow_rules,
      deny_rules: policy.deny_rules,
      gaps: detect_gaps(policy)
    }
  end

  # -- Private: Policy evaluation --

  defp check_hardcoded_deny(resolved) do
    normalized = normalize_for_match(resolved)

    case Enum.find(@hardcoded_deny_patterns, &glob_match?(normalized, &1)) do
      nil ->
        :ok

      pattern ->
        Logger.warning("[Filesystem] Hardcoded deny: #{resolved} matched #{pattern}")
        {:error, "Access denied: path matches hardcoded security policy (#{pattern})"}
    end
  end

  defp check_configured_deny(resolved, policy) do
    normalized = normalize_for_match(resolved)

    case Enum.find(policy.deny_rules, fn rule -> glob_match?(normalized, rule.pattern) end) do
      nil ->
        :ok

      rule ->
        Logger.warning("[Filesystem] Configured deny: #{resolved} matched #{rule.pattern}")
        {:error, "Access denied: path matches deny rule \"#{rule.pattern}\""}
    end
  end

  defp check_configured_allow(_resolved, _operation, %{allow_rules: []}), do: :ok

  defp check_configured_allow(resolved, operation, policy) do
    normalized = normalize_for_match(resolved)

    cond do
      # Data-dir access is now governed by check_data_dir_policy, evaluated
      # before this function. If we reach here, the path is outside the data
      # dir and must match a configured allow rule.
      rule = find_allow_rule(normalized, policy.allow_rules) ->
        check_rule_permissions(rule, operation, resolved)

      true ->
        {:error, "Access denied: path not in any allow rule — #{resolved}"}
    end
  end

  defp find_allow_rule(normalized, rules) do
    Enum.find(rules, fn rule -> glob_match?(normalized, rule.pattern) end)
  end

  defp check_rule_permissions(rule, operation, resolved) do
    if operation in (rule.permissions || [:read]) do
      :ok
    else
      {:error,
       "Access denied: #{operation} not permitted on #{resolved} (allowed: #{inspect(rule.permissions)})"}
    end
  end

  defp check_default_policy(_resolved, _operation, %{allow_rules: rules}) when rules != [] do
    :ok
  end

  defp check_default_policy(resolved, operation, policy) do
    # Data-dir paths are handled by check_data_dir_policy earlier; here we
    # only evaluate paths OUTSIDE the data dir against the default policy.
    if path_in_data_dir?(resolved) do
      :ok
    else
      case policy.default_policy do
        :deny ->
          {:error, "Access denied: default policy is deny-all"}

        :read_only ->
          if operation in [:read, :list, :exists] do
            :ok
          else
            {:error, "Access denied: default policy is read-only, #{operation} not permitted"}
          end

        :allow ->
          :ok

        _ ->
          :ok
      end
    end
  end

  # -- Data-dir specific policy --
  #
  # The Traitee data dir (~/.traitee by default) contains BOTH files the agent
  # legitimately needs to read/write (STM persistence, activity log) AND
  # critical identity/configuration files (config.toml, SOUL.md, credentials,
  # pairing state, dynamic tool registry). We can't blanket-allow the whole
  # directory — that would let the file tool self-reprogram the agent.
  #
  # Policy:
  #   • data_dir/sandbox/** — full rw (designated scratch area)
  #   • data_dir/<protected_writes> — reads allowed, writes denied
  #   • data_dir/<protected_reads>  — all access denied (credentials)
  #   • everything else in data_dir — read allowed, writes allowed but must
  #     still be in an allow rule OR match an "agent-managed" prefix
  #     (messages, logs, etc.).
  defp check_data_dir_policy(resolved, operation) do
    if path_in_data_dir?(resolved) do
      data_dir = normalized_data_dir()
      normalized = normalize_for_match(resolved)
      relative = String.replace_prefix(normalized, data_dir <> "/", "")

      cond do
        # Credentials directory: denied for ALL operations, not just writes.
        matches_any_glob?(relative, @data_dir_protected_reads) ->
          {:error, "Access denied: #{resolved} is a protected Traitee file (credentials)"}

        # Config/identity/skill files: reads OK, writes/exec denied. The LLM
        # has the content via the system prompt already.
        matches_any_glob?(relative, @data_dir_protected_writes) and operation in [:write, :exec] ->
          {:error,
           "Access denied: #{resolved} is a protected Traitee configuration/identity file"}

        # Everything else inside the data dir is permitted. This keeps the
        # data dir usable as the agent's own scratch/memory/logs/cache area
        # while still preventing self-reprogramming and credential theft.
        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp matches_any_glob?(relative, patterns) do
    Enum.any?(patterns, fn pattern ->
      glob_match?(relative, normalize_for_match(pattern))
    end)
  end

  defp path_in_data_dir?(resolved) do
    data_dir = normalized_data_dir()
    normalized = normalize_for_match(resolved)

    String.starts_with?(normalized, data_dir <> "/") or normalized == data_dir
  end

  defp normalized_data_dir do
    Traitee.data_dir() |> Path.expand() |> normalize_for_match()
  end

  defp check_hardcoded_command(command) do
    # Match against both the raw command AND a normalized form that strips
    # cmd.exe caret escapes and collapses whitespace. This defeats `c^url`
    # style evasion without weakening detection of legitimate uses.
    normalized = normalize_command_for_detection(command)

    case Enum.find(@hardcoded_deny_commands, fn pat ->
           Regex.match?(pat, command) or Regex.match?(pat, normalized)
         end) do
      nil ->
        :ok

      pattern ->
        Logger.warning("[Filesystem] Blocked dangerous command: #{truncate_command(command)}")
        {:error, "Command blocked: matches security pattern #{inspect(Regex.source(pattern))}"}
    end
  end

  defp check_configured_command_deny(command, policy) do
    normalized_lc = command |> normalize_command_for_detection() |> String.downcase()
    raw_lc = String.downcase(command)

    case Enum.find(policy.command_deny_patterns, fn pat ->
           if is_binary(pat) do
             needle = String.downcase(pat)
             String.contains?(raw_lc, needle) or String.contains?(normalized_lc, needle)
           else
             Regex.match?(pat, command) or
               Regex.match?(pat, normalize_command_for_detection(command))
           end
         end) do
      nil ->
        :ok

      pat ->
        label = if is_binary(pat), do: pat, else: Regex.source(pat)
        {:error, "Command blocked by configured deny pattern: #{label}"}
    end
  end

  # Strip shell-level evasions before regex matching:
  #  • cmd.exe carets: `c^url` -> `curl`
  #  • backtick interpolation fragments: `cu`r`l` -> `curl`
  #  • collapse runs of whitespace
  defp normalize_command_for_detection(command) do
    command
    |> String.replace("^", "")
    |> String.replace("`", "")
    |> String.replace(~r/\s+/, " ")
  end

  defp check_command_path_refs(command, opts) do
    paths = extract_paths_from_command(command)

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case check_path(path, Keyword.merge(opts, operation: :read, tool: :bash_implicit)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "Command references blocked path: #{reason}"}}
      end
    end)
  end

  # -- Private: Path utilities --

  # Reject path forms that bypass normalization:
  #  • UNC paths (\\server\share): evade anchored globs.
  #  • Long-path prefix (\\?\C:\…): same.
  #  • Device namespaces (\\.\PhysicalDrive0): raw device access.
  #  • NUL-byte injection (would truncate on the OS side).
  #  • 8.3 short names (PROGRA~1): bypass case-normalized globs.
  defp reject_unsafe_path_forms(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, "Access denied: NUL byte in path"}

      String.starts_with?(path, "\\\\?\\") or String.starts_with?(path, "//?/") ->
        {:error, "Access denied: long-path prefix (\\\\?\\) not permitted"}

      String.starts_with?(path, "\\\\.\\") or String.starts_with?(path, "//./") ->
        {:error, "Access denied: device namespace (\\\\.\\) not permitted"}

      String.starts_with?(path, "\\\\") or String.starts_with?(path, "//") ->
        # UNC paths. On Unix, "//" is permitted by POSIX but equivalent to "/";
        # we still reject because downstream globs won't normalize it.
        {:error, "Access denied: UNC path not permitted"}

      Regex.match?(~r/~\d/, Path.basename(path)) ->
        {:error, "Access denied: 8.3 short-name form (~digit) not permitted"}

      windows_reserved_name?(path) ->
        {:error, "Access denied: Windows reserved name (CON/PRN/AUX/NUL/COM*/LPT*)"}

      true ->
        :ok
    end
  end

  defp reject_unsafe_path_forms(_), do: {:error, "Access denied: invalid path"}

  defp windows_reserved_name?(path) do
    base = path |> Path.basename() |> String.downcase()
    stem = String.split(base, ".") |> List.first() || ""

    stem in ~w(con prn aux nul) or
      Regex.match?(~r/^(com|lpt)[0-9]$/, stem)
  end

  # Resolve a path by walking EVERY component through File.read_link, not just
  # the leaf. This closes the attack where an attacker plants a symlink in the
  # middle of a path (e.g., ~/.traitee/link -> /etc) so that only the leaf
  # `/etc/passwd` is examined by the naive leaf-only resolution.
  #
  # Also canonicalizes via Path.expand at each step to eliminate `.`/`..`
  # segments produced by symlink targets.
  defp safe_resolve_path(path) do
    expanded = Path.expand(path)

    case resolve_walk(expanded, 0) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _} = err -> err
    end
  rescue
    _ -> {:error, "Access denied: path resolution failed"}
  end

  @max_symlink_depth 32

  defp resolve_walk(_path, depth) when depth > @max_symlink_depth do
    {:error, "Access denied: symlink chain too deep"}
  end

  defp resolve_walk(path, depth) do
    {root, rest} = split_root(path)
    resolve_components(root, rest, depth)
  end

  defp split_root(path) do
    cond do
      # Windows drive letter (C:/…)
      match = Regex.run(~r/^([A-Za-z]:)[\/\\](.*)$/, path) ->
        [_, drive, rest] = match
        {drive <> "/", String.split(rest, ~r/[\/\\]+/, trim: true)}

      # Drive letter with no separator (C:)
      match = Regex.run(~r/^([A-Za-z]:)$/, path) ->
        [_, drive] = match
        {drive <> "/", []}

      # Unix absolute
      String.starts_with?(path, "/") ->
        {"/", String.split(String.trim_leading(path, "/"), ~r/[\/\\]+/, trim: true)}

      # Relative (shouldn't happen post-expand, but be defensive)
      true ->
        {".", String.split(path, ~r/[\/\\]+/, trim: true)}
    end
  end

  defp resolve_components(current, [], _depth) do
    final =
      case File.read_link(current) do
        {:ok, target} ->
          target |> Path.expand(Path.dirname(current))

        {:error, _} ->
          current
      end

    {:ok, Path.expand(final)}
  end

  defp resolve_components(current, [component | rest], depth) do
    next_raw = Path.join(current, component)

    case File.read_link(next_raw) do
      {:ok, target} ->
        resolved_target = Path.expand(target, Path.dirname(next_raw))
        resolve_walk(Path.join([resolved_target] ++ rest), depth + 1)

      {:error, _} ->
        resolve_components(next_raw, rest, depth)
    end
  end

  defp normalize_for_match(path) do
    path
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  @doc false
  def glob_match?(path, pattern) do
    normalized_pattern = normalize_for_match(pattern)
    regex = glob_to_regex(normalized_pattern)
    Regex.match?(regex, path)
  end

  defp glob_to_regex(pattern) do
    parts = String.split(pattern, "**")

    regex_str =
      Enum.map_join(parts, ".*", fn part ->
        part
        |> String.replace(".", "\\.")
        |> String.replace("*", "[^/]*")
        |> String.replace("?", "[^/]")
      end)

    Regex.compile!("^#{regex_str}$", "i")
  end

  defp extract_paths_from_command(command) do
    # Strip cmd.exe caret escapes and quotes up front so we don't miss paths
    # hidden by `c^url "/etc/passwd"`.
    cleaned =
      command
      |> String.replace(~r/\^/, "")
      |> String.replace(~r/["']/, " ")

    unix_paths =
      Regex.scan(~r{(?:^|[\s=|;&(<>])(/[^\s"';|&<>]+)}, cleaned) |> Enum.map(&List.last/1)

    win_paths =
      Regex.scan(~r{(?:^|[\s=|;&(<>])([A-Za-z]:[\\\/][^\s"';|&<>]+)}, cleaned)
      |> Enum.map(&List.last/1)

    home_paths =
      Regex.scan(~r{(?:^|[\s=|;&(<>])(~[/\\][^\s"';|&<>]+)}, cleaned)
      |> Enum.map(&List.last/1)

    env_paths =
      Regex.scan(
        ~r{(?:^|[\s=|;&(<>])(\$(?:HOME|USERPROFILE|APPDATA|LOCALAPPDATA)[/\\][^\s"';|&<>]+)},
        cleaned
      )
      |> Enum.map(&List.last/1)

    winenv_paths =
      Regex.scan(~r{(?:^|[\s=|;&(<>])(%[A-Za-z_]+%[\\\/][^\s"';|&<>]+)}, cleaned)
      |> Enum.map(&List.last/1)

    (unix_paths ++ win_paths ++ home_paths ++ env_paths ++ winenv_paths)
    |> Enum.filter(&(String.length(&1) > 3))
    |> Enum.uniq()
  end

  # -- Private: Config loading --

  defp load_config do
    fs_config = Traitee.Config.get([:security, :filesystem]) || %{}
    tools_config = Traitee.Config.get(:tools) || %{}
    sandbox_mode = resolve_sandbox_mode(fs_config, tools_config)

    base_config(fs_config, tools_config, sandbox_mode)
    |> Map.merge(parse_docker_config(fs_config[:docker] || %{}))
    |> Map.merge(parse_exec_gate_config(fs_config[:exec_gate] || %{}))
    |> Map.merge(parse_audit_config(fs_config[:audit] || %{}))
  end

  defp resolve_sandbox_mode(fs_config, tools_config) do
    case fs_config[:sandbox_mode] do
      nil -> (tools_config[:bash] || %{})[:sandbox] == true
      val -> val == true
    end
  end

  defp base_config(fs_config, tools_config, sandbox_mode) do
    %{
      sandbox_mode: sandbox_mode,
      default_policy: parse_default_policy(fs_config[:default_policy], sandbox_mode),
      allow_rules:
        parse_path_rules(
          fs_config[:allow] || fs_config[:allow_rules] || legacy_allow_paths(tools_config)
        ),
      deny_rules: parse_path_rules(fs_config[:deny] || fs_config[:deny_rules] || []),
      command_deny_patterns: parse_command_patterns(fs_config[:command_deny] || []),
      working_dir: (tools_config[:bash] || %{})[:working_dir] || fs_config[:working_dir]
    }
  end

  defp parse_docker_config(docker) do
    %{
      docker_enabled: docker[:enabled] == true,
      docker_image: docker[:image] || "alpine:latest",
      docker_memory: docker[:memory] || "256m",
      docker_cpus: docker[:cpus] || "0.5",
      docker_network: docker[:network] || "none"
    }
  end

  defp parse_exec_gate_config(gate) do
    %{
      exec_gate_enabled: gate[:enabled] == true,
      exec_gate_rules: parse_exec_gate_rules(gate[:rules] || [])
    }
  end

  defp parse_audit_config(audit) do
    %{audit_enabled: audit[:enabled] != false}
  end

  defp parse_default_policy(nil, true), do: :deny
  defp parse_default_policy(nil, false), do: :read_only
  defp parse_default_policy("deny", _), do: :deny
  defp parse_default_policy("read_only", _), do: :read_only
  defp parse_default_policy("allow", _), do: :allow
  defp parse_default_policy(val, _) when is_atom(val), do: val
  defp parse_default_policy(_, sandbox), do: if(sandbox, do: :deny, else: :read_only)

  defp legacy_allow_paths(tools_config) do
    paths = (tools_config[:file] || %{})[:allowed_paths] || []

    Enum.map(paths, fn path ->
      %{pattern: path <> "/**", permissions: [:read, :write]}
    end)
  end

  defp parse_path_rules(rules) when is_list(rules) do
    Enum.map(rules, fn
      rule when is_binary(rule) ->
        %{pattern: rule, permissions: [:read]}

      rule when is_map(rule) ->
        %{
          pattern: rule[:pattern] || rule["pattern"] || "**",
          permissions: parse_permissions(rule[:permissions] || rule["permissions"] || [:read])
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_path_rules(_), do: []

  defp parse_permissions(perms) when is_list(perms) do
    Enum.map(perms, fn
      p when is_atom(p) -> p
      p when is_binary(p) -> String.to_existing_atom(p)
    end)
  rescue
    _ -> [:read]
  end

  defp parse_permissions("read"), do: [:read]
  defp parse_permissions("write"), do: [:read, :write]
  defp parse_permissions("readwrite"), do: [:read, :write]
  defp parse_permissions(_), do: [:read]

  defp parse_command_patterns(patterns) when is_list(patterns) do
    Enum.map(patterns, fn
      pat when is_binary(pat) -> pat
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_command_patterns(_), do: []

  defp parse_exec_gate_rules(rules) when is_list(rules) do
    Enum.map(rules, fn
      rule when is_map(rule) ->
        %{
          pattern: rule[:pattern] || rule["pattern"] || "*",
          action: parse_gate_action(rule[:action] || rule["action"] || "warn"),
          description: rule[:description] || rule["description"] || ""
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_exec_gate_rules(_), do: []

  defp parse_gate_action("approve"), do: :approve
  defp parse_gate_action("warn"), do: :warn
  defp parse_gate_action("deny"), do: :deny
  defp parse_gate_action(a) when is_atom(a), do: a
  defp parse_gate_action(_), do: :warn

  # -- Private: Audit emission --

  defp emit_audit(event_type, details) do
    if audit_enabled?() do
      Traitee.Security.Audit.record(event_type, details)
    end
  rescue
    _ -> :ok
  end

  defp audit_enabled? do
    case :ets.whereis(@table) do
      :undefined ->
        false

      _ ->
        case :ets.lookup(@table, :policy) do
          [{:policy, %{audit_enabled: true}}] -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  # -- Private: Helpers --

  defp format_decision_reason(:ok), do: "allowed"
  defp format_decision_reason({:error, reason}), do: reason

  defp truncate_command(cmd) when byte_size(cmd) > 200 do
    String.slice(cmd, 0, 200) <> "..."
  end

  defp truncate_command(cmd), do: cmd

  defp summarize_policy(policy) do
    %{
      sandbox: policy.sandbox_mode,
      default: policy.default_policy,
      allow_count: length(policy.allow_rules),
      deny_count: length(policy.deny_rules),
      docker: policy.docker_enabled,
      exec_gate: policy.exec_gate_enabled
    }
  end

  defp detect_gaps(policy) do
    []
    |> maybe_gap(policy.sandbox_mode, "sandbox_mode disabled — commands run without isolation")
    |> maybe_gap(
      policy.allow_rules != [] or policy.default_policy == :deny,
      "no allow rules and default policy is not deny — broad filesystem access possible"
    )
    |> maybe_gap(
      policy.exec_gate_enabled,
      "exec approval gates disabled — all commands auto-approved"
    )
    |> maybe_gap(policy.docker_enabled, "docker isolation disabled — tools run in host process")
    |> maybe_gap(policy.audit_enabled, "audit logging disabled — no filesystem access trail")
    |> maybe_gap(
      policy.deny_rules != [],
      "no custom deny rules — relying only on hardcoded patterns"
    )
    |> Enum.reverse()
  end

  defp maybe_gap(gaps, true, _msg), do: gaps
  defp maybe_gap(gaps, false, msg), do: [msg | gaps]

  @doc false
  def valid_operations, do: @operations
end
