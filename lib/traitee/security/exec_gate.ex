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

  @default_gates [
    %{
      pattern: "rm *",
      action: :warn,
      description: "Destructive file removal"
    },
    %{
      pattern: "chmod *",
      action: :warn,
      description: "Permission changes"
    },
    %{
      pattern: "git push *",
      action: :warn,
      description: "Remote git operations"
    },
    %{
      pattern: "npm publish*",
      action: :deny,
      description: "Package publishing"
    },
    %{
      pattern: "pip install*",
      action: :warn,
      description: "Package installation"
    },
    %{
      pattern: "curl *",
      action: :warn,
      description: "External HTTP requests"
    },
    %{
      pattern: "wget *",
      action: :warn,
      description: "External HTTP downloads"
    },
    %{
      pattern: "docker *",
      action: :warn,
      description: "Docker operations"
    },
    %{
      pattern: "sudo *",
      action: :deny,
      description: "Elevated privilege execution"
    },
    %{
      pattern: "powershell *-ExecutionPolicy*",
      action: :deny,
      description: "PowerShell policy bypass"
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
    if enabled?() do
      expanded = Path.expand(path)

      system_dirs = [
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/opt",
        "/boot",
        "/lib",
        "/lib64",
        "C:/Windows",
        "C:/Program Files",
        "C:/Program Files (x86)"
      ]

      normalized = String.replace(expanded, "\\", "/") |> String.downcase()

      is_system =
        Enum.any?(system_dirs, fn dir ->
          String.starts_with?(normalized, String.downcase(dir))
        end)

      if is_system do
        Logger.warning("[ExecGate] Denied write to system path: #{expanded}")

        Audit.record(:exec_gate, %{
          path: expanded,
          decision: :deny,
          reason: "Write to system directory blocked",
          tool: Keyword.get(opts, :tool, :unknown),
          session_id: Keyword.get(opts, :session_id)
        })

        {:error, "Write to system directory blocked: #{expanded}"}
      else
        :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
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
    normalized = String.downcase(command_or_path)

    Enum.find(rules, fn rule ->
      pattern = String.downcase(rule.pattern)
      simple_glob_match?(normalized, pattern)
    end)
  end

  defp simple_glob_match?(text, pattern) do
    cond do
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
