defmodule Traitee.Security.Docker do
  @moduledoc """
  Docker container isolation layer for tool execution.

  When enabled, shell commands and script executions run inside ephemeral
  Docker containers with:
  - Read-only root filesystem
  - No network access (default)
  - Memory and CPU limits
  - Selective bind mounts based on filesystem allow rules
  - Automatic cleanup on completion or timeout

  Falls back to host execution if Docker is unavailable, logging a warning.
  """

  require Logger

  alias Traitee.Security.Filesystem

  @doc """
  Execute a command inside a Docker container with security constraints.

  Returns `{:ok, %{stdout: ..., exit_code: ...}}` or `{:error, reason}`.

  ## Options
    - `:timeout_ms` — execution timeout (default: 30_000)
    - `:working_dir` — working directory inside container
    - `:env` — environment variables as `[{key, value}]`
    - `:mounts` — additional bind mounts as `[{host_path, container_path, mode}]`
    - `:network` — network mode (default: "none")
    - `:session_id` — for audit trail
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(command, opts \\ []) do
    if enabled?() do
      case check_docker_available() do
        :ok ->
          execute_in_container(command, opts)

        {:error, reason} ->
          Logger.warning(
            "[Docker] Docker unavailable: #{reason} — falling back to host execution"
          )

          {:error, {:docker_unavailable, reason}}
      end
    else
      {:error, :docker_disabled}
    end
  end

  @doc "Check if Docker isolation is enabled in config."
  @spec enabled?() :: boolean()
  def enabled? do
    Filesystem.current_policy().docker_enabled
  rescue
    _ -> false
  end

  @doc "Check if Docker is installed and the daemon is running."
  @spec check_docker_available() :: :ok | {:error, String.t()}
  def check_docker_available do
    case System.cmd("docker", ["info", "--format", "{{.ServerVersion}}"], stderr_to_stdout: true) do
      {version, 0} ->
        Logger.debug("[Docker] Docker available: v#{String.trim(version)}")
        :ok

      {output, _code} ->
        {:error, "Docker daemon not responding: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "Docker not found: #{Exception.message(e)}"}
  end

  @doc """
  Returns the Docker security posture for the audit report.
  """
  @spec posture() :: map()
  def posture do
    policy = Filesystem.current_policy()

    available =
      case check_docker_available() do
        :ok -> true
        _ -> false
      end

    %{
      enabled: policy.docker_enabled,
      available: available,
      image: policy.docker_image,
      memory: policy.docker_memory,
      cpus: policy.docker_cpus,
      network: policy.docker_network,
      status:
        cond do
          not policy.docker_enabled -> :disabled
          not available -> :unavailable
          true -> :active
        end
    }
  end

  # -- Private --

  defp execute_in_container(command, opts) do
    policy = Filesystem.current_policy()
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    working_dir = Keyword.get(opts, :working_dir, "/workspace")
    env_vars = Keyword.get(opts, :env, [])
    extra_mounts = Keyword.get(opts, :mounts, [])

    mounts = build_mounts(policy, extra_mounts)
    env_flags = build_env_flags(env_vars)
    container_name = "traitee-sandbox-#{System.unique_integer([:positive])}"

    docker_args =
      [
        "run",
        "--rm",
        "--name",
        container_name,
        "--read-only",
        "--network",
        policy.docker_network,
        "--memory",
        policy.docker_memory,
        "--cpus",
        policy.docker_cpus,
        "--pids-limit",
        "100",
        "--tmpfs",
        "/tmp:rw,noexec,nosuid,size=64m",
        "--security-opt",
        "no-new-privileges",
        "--workdir",
        working_dir
      ] ++
        mounts ++
        env_flags ++
        [
          policy.docker_image,
          "/bin/sh",
          "-c",
          command
        ]

    Traitee.Security.Audit.record(:docker_exec, %{
      command: truncate(command),
      container: container_name,
      image: policy.docker_image,
      network: policy.docker_network,
      decision: :allow
    })

    task =
      Task.async(fn ->
        case System.cmd("docker", docker_args, stderr_to_stdout: true) do
          {output, exit_code} -> {:ok, %{stdout: output, exit_code: exit_code}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        kill_container(container_name)
        {:error, :timeout}
    end
  rescue
    e -> {:error, "Docker execution failed: #{Exception.message(e)}"}
  end

  defp build_mounts(policy, extra_mounts) do
    sandbox_dir = Filesystem.sandbox_working_dir()
    File.mkdir_p!(sandbox_dir)

    allow_mounts =
      policy.allow_rules
      |> Enum.filter(fn rule ->
        pattern = rule.pattern
        not String.contains?(pattern, "*") and File.exists?(String.trim_trailing(pattern, "/"))
      end)
      |> Enum.map(fn rule ->
        host_path = String.trim_trailing(rule.pattern, "/**") |> Path.expand()
        mode = if :write in (rule.permissions || []), do: "rw", else: "ro"
        {host_path, host_path, mode}
      end)

    all_mounts =
      [{sandbox_dir, "/workspace", "rw"}] ++ allow_mounts ++ extra_mounts

    Enum.flat_map(all_mounts, fn {host, container, mode} ->
      ["-v", "#{host}:#{container}:#{mode}"]
    end)
  end

  defp build_env_flags(env_vars) do
    Enum.flat_map(env_vars, fn
      {k, v} when is_list(k) -> ["-e", "#{to_string(k)}=#{to_string(v)}"]
      {k, v} -> ["-e", "#{k}=#{v}"]
    end)
  end

  defp kill_container(name) do
    Task.start(fn ->
      System.cmd("docker", ["kill", name], stderr_to_stdout: true)
    end)
  end

  defp truncate(str) when byte_size(str) > 200, do: String.slice(str, 0, 200) <> "..."
  defp truncate(str), do: str
end
