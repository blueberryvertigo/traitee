defmodule Traitee.Security.Sandbox do
  @moduledoc """
  Centralized sandbox enforcement layer for all tool execution.

  Integrates the filesystem policy engine, audit trail, exec gates,
  and Docker isolation into a single API that tools call before any
  filesystem or command operation.

  Unlike the previous opt-in model, sandbox enforcement is now global:
  - `check_path/2` is called by ALL tools (file, bash implicit paths, dynamic)
  - `check_command/2` is called by ALL command-executing tools
  - `check_write/2` routes through exec gates for system-dir protection
  - Docker isolation wraps execution when enabled

  This module delegates to specialized subsystems:
  - `Traitee.Security.Filesystem` — path/command policy evaluation
  - `Traitee.Security.Audit` — structured event logging
  - `Traitee.Security.ExecGate` — approval gates
  - `Traitee.Security.Docker` — container isolation
  """

  require Logger

  alias Traitee.Security.{Audit, Docker, ExecGate, Filesystem}

  # -- Path validation (delegates to Filesystem) --

  @doc """
  Check whether a file path is safe to access for the given operation.

  Always enforced regardless of sandbox mode. Evaluates against:
  1. Hardcoded deny list (sensitive paths)
  2. Configured deny rules
  3. Configured allow rules with per-path permissions
  4. Default policy
  5. Exec gate for writes

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_path(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_path(path, opts \\ []) do
    operation = Keyword.get(opts, :operation, :read)

    with :ok <- Filesystem.check_path(path, opts),
         :ok <- maybe_exec_gate_write(path, operation, opts) do
      :ok
    end
  end

  @doc "Returns the list of hardcoded blocked path patterns."
  @spec blocked_path_patterns() :: [String.t()]
  def blocked_path_patterns, do: Filesystem.hardcoded_deny_patterns()

  @doc "Returns the list of hardcoded blocked filenames (legacy compat)."
  @spec blocked_filenames() :: [String.t()]
  def blocked_filenames do
    [
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
  end

  # -- Command validation (delegates to Filesystem + ExecGate) --

  @doc """
  Check whether a shell command is safe to execute.

  Always enforced — sandbox mode controls Docker isolation and working
  directory jailing, but command validation runs regardless.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_command(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_command(command, opts \\ []) do
    with :ok <- Filesystem.check_command(command, opts),
         :ok <- maybe_exec_gate_command(command, opts) do
      :ok
    end
  end

  # -- Environment scrubbing (delegates to Filesystem) --

  @doc """
  Returns a scrubbed environment variable list safe for child processes.
  Always active — secrets are never passed to tool subprocesses.
  """
  @spec scrubbed_env() :: [{charlist(), charlist()}]
  def scrubbed_env, do: Filesystem.scrubbed_env()

  # -- Sandbox mode queries --

  @doc "Returns whether sandbox mode is enabled (controls Docker + working dir jail)."
  @spec sandbox_enabled?() :: boolean()
  def sandbox_enabled?, do: Filesystem.sandbox_enabled?()

  @doc "Returns the sandbox working directory."
  @spec sandbox_working_dir() :: String.t()
  def sandbox_working_dir, do: Filesystem.sandbox_working_dir()

  # -- Docker-wrapped execution --

  @doc """
  Execute a command with full sandbox enforcement.

  When Docker isolation is enabled and available, runs in a container.
  Otherwise runs via the process executor with env scrubbing and
  working directory constraints.

  Always validates the command through check_command first.
  """
  @spec execute(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(command, opts \\ []) do
    with :ok <- check_command(command, opts) do
      if Docker.enabled?() do
        case Docker.run(command, opts) do
          {:ok, result} ->
            {:ok, result}

          {:error, {:docker_unavailable, _}} ->
            Logger.warning("[Sandbox] Docker unavailable, falling back to host execution")
            execute_host(command, opts)

          {:error, reason} ->
            {:error, reason}
        end
      else
        execute_host(command, opts)
      end
    end
  end

  # -- Posture summary --

  @doc "Returns a comprehensive security posture summary."
  @spec posture() :: map()
  def posture do
    fs = Filesystem.posture_summary()
    docker = Docker.posture()
    audit_stats = Audit.stats()

    Map.merge(fs, %{
      docker: docker,
      audit: audit_stats,
      exec_gate_rules: ExecGate.active_rules()
    })
  end

  # -- Private --

  defp execute_host(command, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    working_dir = Keyword.get(opts, :working_dir)
    env = scrubbed_env()

    Traitee.Process.Executor.run(command,
      timeout_ms: timeout,
      working_dir: working_dir,
      env: env
    )
  end

  defp maybe_exec_gate_write(_path, operation, _opts) when operation in [:read, :list, :exists] do
    :ok
  end

  defp maybe_exec_gate_write(path, _operation, opts) do
    ExecGate.check_write(path, opts)
  end

  defp maybe_exec_gate_command(command, opts) do
    case ExecGate.evaluate(command, opts) do
      {:approve, _reason} -> :ok
      {:warn, _reason} -> :ok
      {:deny, reason} -> {:error, "Exec gate denied: #{reason}"}
    end
  end
end
