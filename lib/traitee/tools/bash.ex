defmodule Traitee.Tools.Bash do
  @moduledoc """
  Shell command execution tool with cross-platform Windows/Unix support.
  When sandbox mode is enabled, commands are validated against a blocklist,
  environment variables are scrubbed, and execution is jailed to a working directory.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Security.Sandbox

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
    sandboxed? = Sandbox.sandbox_enabled?()
    timeout = args["timeout"] || @default_timeout

    with :ok <- maybe_check_command(command, sandboxed?) do
      working_dir = resolve_working_dir(args["working_directory"], sandboxed?)
      env = if sandboxed?, do: Sandbox.scrubbed_env(), else: []

      case Traitee.Process.Executor.run(command,
             timeout_ms: timeout,
             working_dir: working_dir,
             env: env
           ) do
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

  defp maybe_check_command(command, true), do: Sandbox.check_command(command)
  defp maybe_check_command(_command, false), do: :ok

  defp resolve_working_dir(nil, true) do
    dir = Sandbox.sandbox_working_dir()
    File.mkdir_p!(dir)
    dir
  end

  defp resolve_working_dir(dir, true) when is_binary(dir) do
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
  end

  defp resolve_working_dir(dir, false), do: dir

  defp truncate(output) do
    if String.length(output) > @max_output do
      String.slice(output, 0, @max_output) <> "\n... (truncated)"
    else
      output
    end
  end
end
