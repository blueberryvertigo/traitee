defmodule Traitee.Tools.Bash do
  @moduledoc "Shell command execution tool with cross-platform Windows/Unix support."

  @behaviour Traitee.Tools.Tool

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
    working_dir = args["working_directory"]
    timeout = args["timeout"] || @default_timeout

    case Traitee.Process.Executor.run(command,
           timeout_ms: timeout,
           working_dir: working_dir
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

  def execute(_), do: {:error, "Missing required parameter: command"}

  defp truncate(output) do
    if String.length(output) > @max_output do
      String.slice(output, 0, @max_output) <> "\n... (truncated)"
    else
      output
    end
  end
end
