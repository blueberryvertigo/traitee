defmodule Traitee.Tools.Bash do
  @moduledoc """
  Shell command execution tool with cross-platform Windows/Unix support.

  All commands are validated through the centralized sandbox — command
  blocklist, filesystem policy, exec gates, and environment scrubbing
  are always enforced regardless of sandbox mode. When sandbox mode is
  active, execution is additionally jailed to a working directory and
  optionally routed through Docker container isolation.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Process.Executor
  alias Traitee.Security.{Docker, Sandbox}

  @max_output 10_000
  @default_timeout 30_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Execute a shell command and return its output. Use for system operations, file manipulation, and running programs."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "The shell command to execute"
        },
        "working_directory" => %{
          "type" => "string",
          "description" => "Optional working directory for the command"
        },
        "timeout" => %{
          "type" => "integer",
          "description" => "Timeout in milliseconds (default: 30000)"
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(%{"command" => command} = args) do
    timeout = args["timeout"] || @default_timeout
    session_id = args["_session_id"]

    with :ok <- Sandbox.check_command(command, tool: "bash", session_id: session_id) do
      working_dir = resolve_working_dir(args["working_directory"])
      env = Sandbox.scrubbed_env()

      result =
        if Docker.enabled?() do
          Docker.run(command,
            timeout_ms: timeout,
            working_dir: working_dir,
            env: env,
            session_id: session_id
          )
          |> docker_fallback(command, timeout, working_dir, env)
        else
          Executor.run(command,
            timeout_ms: timeout,
            working_dir: working_dir,
            env: env
          )
        end

      case result do
        {:ok, %{stdout: output, exit_code: 0}} ->
          {:ok, truncate(output)}

        {:ok, %{stdout: output, exit_code: code}} ->
          {:ok, "Exit code #{code}:\n#{truncate(output)}"}

        {:error, :timeout} ->
          {:error, "Command timed out after #{timeout}ms"}

        {:error, reason} ->
          {:error, "Command failed: #{inspect(reason)}"}
      end
    end
  end

  def execute(_), do: {:error, "Missing required parameter: command"}

  defp docker_fallback({:ok, result}, _cmd, _timeout, _dir, _env), do: {:ok, result}

  defp docker_fallback({:error, {:docker_unavailable, _}}, cmd, timeout, dir, env) do
    Executor.run(cmd, timeout_ms: timeout, working_dir: dir, env: env)
  end

  defp docker_fallback({:error, reason}, _cmd, _timeout, _dir, _env), do: {:error, reason}

  defp resolve_working_dir(nil) do
    if Sandbox.sandbox_enabled?() do
      dir = Sandbox.sandbox_working_dir()
      File.mkdir_p!(dir)
      dir
    else
      nil
    end
  end

  defp resolve_working_dir(dir) when is_binary(dir) do
    if Sandbox.sandbox_enabled?() do
      sandbox_root = Sandbox.sandbox_working_dir()
      expanded = Path.expand(dir)

      normalized_root = String.replace(sandbox_root, "\\", "/")
      normalized_dir = String.replace(expanded, "\\", "/")

      if String.starts_with?(normalized_dir, normalized_root) do
        File.mkdir_p!(expanded)
        expanded
      else
        File.mkdir_p!(sandbox_root)
        sandbox_root
      end
    else
      dir
    end
  end

  defp truncate(output) do
    if String.length(output) > @max_output do
      String.slice(output, 0, @max_output) <> "\n... (truncated)"
    else
      output
    end
  end
end
