defmodule Traitee.Security.ExecGate do
  @moduledoc """
  Execution approval gates for tool operations.

  Evaluates tool invocations against configurable rules to decide:
  - `:approve` — auto-approved, proceed silently
  - `:warn` — log a warning but allow
  - `:deny` — block execution

  Rules match against tool name, command content, and file paths using
  glob patterns. When no rules match, the default action applies.

  Categories of gated operations:
  - Shell commands (bash tool)
  - File write operations
  - Dynamic tool execution
  - Script execution
  - Network-accessing commands
  """

  require Logger

  alias Traitee.Security.{Audit, Filesystem}

  # Rules are evaluated in order — :deny rules must come BEFORE their
  # enclosing :warn rules so that `sudo rm …` is denied (matches sudo first)
  # rather than warned (would match `rm ` otherwise).
  @default_gates [
    # -- Denies (specific, evaluated first) --
    %{
      pattern: "sudo ",
      action: :deny,
      description: "Elevated privilege execution"
    },
    %{
      pattern: "pkexec",
      action: :deny,
      description: "Elevated privilege execution"
    },
    %{
      pattern: "doas",
      action: :deny,
      description: "Elevated privilege execution"
    },
    %{
      pattern: "runas ",
      action: :deny,
      description: "Elevated privilege execution"
    },
    %{
      pattern: "docker",
      action: :deny,
      description: "Container runtime access from the bash tool (host escape)"
    },
    %{
      pattern: "podman",
      action: :deny,
      description: "Container runtime access"
    },
    %{
      pattern: "kubectl",
      action: :deny,
      description: "Kubernetes control"
    },
    %{
      pattern: "-executionpolicy",
      action: :deny,
      description: "PowerShell policy bypass"
    },
    %{
      pattern: "-encodedcommand",
      action: :deny,
      description: "PowerShell encoded command"
    },
    %{
      pattern: "bitsadmin",
      action: :deny,
      description: "Windows BITS download abuse"
    },
    %{
      pattern: "mshta",
      action: :deny,
      description: "Windows HTA script execution"
    },
    %{
      pattern: "npm publish",
      action: :deny,
      description: "Package publishing"
    },
    # -- Warns (broader, evaluated last) --
    %{
      pattern: "rm ",
      action: :warn,
      description: "Destructive file removal"
    },
    %{
      pattern: "chmod ",
      action: :warn,
      description: "Permission changes"
    },
    %{
      pattern: "git push",
      action: :warn,
      description: "Remote git operations"
    },
    %{
      pattern: "pip install",
      action: :warn,
      description: "Package installation"
    },
    %{
      pattern: "curl ",
      action: :warn,
      description: "External HTTP requests"
    },
    %{
      pattern: "wget ",
      action: :warn,
      description: "External HTTP downloads"
    }
  ]

  @doc """
  Evaluate a tool invocation through the exec gate.

  Returns `{:approve, reason}`, `{:warn, reason}`, or `{:deny, reason}`.

  ## Options
    - `:tool` — the tool name (e.g., "bash", "file")
    - `:operation` — the operation type (e.g., :write, :exec)
    - `:session_id` — session ID for audit trail
  """
  @spec evaluate(String.t(), keyword()) ::
          {:approve, String.t()} | {:warn, String.t()} | {:deny, String.t()}
  def evaluate(command_or_path, opts \\ []) do
    if enabled?() do
      tool = Keyword.get(opts, :tool, "unknown")
      rules = active_rules()

      case find_matching_rule(command_or_path, tool, rules) do
        nil ->
          {:approve, "no matching gate rule"}

        %{action: :approve} = rule ->
          {:approve, rule.description}

        %{action: :warn} = rule ->
          Logger.warning(
            "[ExecGate] Warning: #{tool} — #{rule.description} — #{truncate(command_or_path)}"
          )

          emit_audit(:warn, command_or_path, rule, opts)
          {:warn, rule.description}

        %{action: :deny} = rule ->
          Logger.warning(
            "[ExecGate] Denied: #{tool} — #{rule.description} — #{truncate(command_or_path)}"
          )

          emit_audit(:deny, command_or_path, rule, opts)
          {:deny, rule.description}
      end
    else
      {:approve, "exec gates disabled"}
    end
  end

  @doc """
  Check a file write operation through the exec gate.
  Write operations to system directories get extra scrutiny.
  """
  @spec check_write(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_write(path, opts \\ []) do
    # Always enforce system-dir write protection regardless of exec_gate config
    # toggle — this is a last line of defense and disabling it by config would
    # be a silent foot-gun. We still respect the toggle for auxiliary rules.
    expanded = Path.expand(path)

    system_dirs = [
      "/usr/",
      "/bin/",
      "/sbin/",
      "/etc/",
      "/var/",
      "/opt/",
      "/boot/",
      "/lib/",
      "/lib64/",
      "/root/",
      "/proc/",
      "/sys/",
      "/dev/",
      "c:/windows/",
      "c:/program files/",
      "c:/program files (x86)/",
      "c:/programdata/microsoft/"
    ]

    # Persistence-path suffix patterns (match anywhere): startup folders,
    # systemd user units, shell rc files.
    persistence_fragments = [
      "/appdata/roaming/microsoft/windows/start menu/programs/startup/",
      "/.config/systemd/",
      "/.config/autostart/",
      "/.bashrc",
      "/.bash_profile",
      "/.zshrc",
      "/.profile",
      "/$profile"
    ]

    normalized = expanded |> String.replace("\\", "/") |> String.downcase()

    is_system =
      Enum.any?(system_dirs, fn dir ->
        String.starts_with?(normalized, dir)
      end) or
        Enum.any?(persistence_fragments, fn fragment ->
          String.contains?(normalized, fragment)
        end)

    if is_system do
      Logger.warning("[ExecGate] Denied write to system/persistence path: #{expanded}")

      Audit.record(:exec_gate, %{
        path: expanded,
        decision: :deny,
        reason: "Write to system or persistence directory blocked",
        tool: Keyword.get(opts, :tool, :unknown),
        session_id: Keyword.get(opts, :session_id)
      })

      {:error, "Write to system/persistence directory blocked: #{expanded}"}
    else
      :ok
    end
  rescue
    _ -> {:error, "Write check failed — fail-closed"}
  end

  @doc "Returns whether exec gates are enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    policy = Filesystem.current_policy()
    policy.exec_gate_enabled
  rescue
    _ -> false
  end

  @doc "Returns the currently active rules (configured + defaults)."
  @spec active_rules() :: [map()]
  def active_rules do
    configured =
      try do
        Filesystem.current_policy().exec_gate_rules
      rescue
        _ -> []
      end

    if configured == [] do
      @default_gates
    else
      configured
    end
  end

  @doc "Returns the default gate rules for inspection."
  @spec default_gates() :: [map()]
  def default_gates, do: @default_gates

  # -- Private --

  defp find_matching_rule(command_or_path, _tool, rules) do
    # Check both raw and evasion-normalized forms so cmd.exe carets and
    # backtick fragmentation don't slip past rule patterns.
    raw = String.downcase(command_or_path)
    normalized = raw |> String.replace("^", "") |> String.replace("`", "")

    Enum.find(rules, fn rule ->
      pattern = String.downcase(rule.pattern)
      simple_glob_match?(raw, pattern) or simple_glob_match?(normalized, pattern)
    end)
  end

  defp simple_glob_match?(text, pattern) do
    cond do
      String.ends_with?(pattern, "*") and String.starts_with?(pattern, "*") ->
        inner = pattern |> String.trim_leading("*") |> String.trim_trailing("*")
        String.contains?(text, inner)

      String.ends_with?(pattern, "*") ->
        prefix = String.trim_trailing(pattern, "*")
        String.starts_with?(text, prefix)

      String.starts_with?(pattern, "*") ->
        suffix = String.trim_leading(pattern, "*")
        String.contains?(text, suffix)

      true ->
        String.contains?(text, pattern)
    end
  end

  defp emit_audit(decision, command_or_path, rule, opts) do
    Audit.record(:exec_gate, %{
      command: truncate(command_or_path),
      decision: decision,
      reason: rule.description,
      pattern: rule.pattern,
      tool: Keyword.get(opts, :tool, :unknown),
      session_id: Keyword.get(opts, :session_id)
    })
  rescue
    _ -> :ok
  end

  defp truncate(str) when byte_size(str) > 200, do: String.slice(str, 0, 200) <> "..."
  defp truncate(str), do: str
end
