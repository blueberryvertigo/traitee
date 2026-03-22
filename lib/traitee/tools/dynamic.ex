defmodule Traitee.Tools.Dynamic do
  @moduledoc """
  Execution engine for dynamically registered script-based tools.
  Supports bash template and script file executor types.
  """

  alias Traitee.Process.Executor

  @max_output 10_000
  @default_timeout 30_000

  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          parameters_schema: map(),
          executor: {:bash, String.t()} | {:script, String.t()},
          enabled: boolean()
        }

  @spec execute(tool_spec(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{executor: {:bash, template}}, args) do
    command = interpolate(template, args)

    case Executor.run(command, timeout_ms: @default_timeout) do
      {:ok, %{stdout: output, exit_code: 0}} ->
        {:ok, truncate(output)}

      {:ok, %{stdout: output, exit_code: code}} ->
        {:ok, "Exit code #{code}:\n#{truncate(output)}"}

      {:error, :timeout} ->
        {:error, "Tool timed out after #{@default_timeout}ms"}

      {:error, reason} ->
        {:error, "Tool failed: #{inspect(reason)}"}
    end
  end

  def execute(%{executor: {:script, path}}, args) do
    json_args = Jason.encode!(args)

    command =
      case Path.extname(path) do
        ".py" -> "echo #{shell_escape(json_args)} | python #{shell_escape(path)}"
        ".sh" -> "echo #{shell_escape(json_args)} | bash #{shell_escape(path)}"
        ".js" -> "echo #{shell_escape(json_args)} | node #{shell_escape(path)}"
        _ -> "echo #{shell_escape(json_args)} | #{shell_escape(path)}"
      end

    case Executor.run(command, timeout_ms: @default_timeout) do
      {:ok, %{stdout: output, exit_code: 0}} ->
        {:ok, truncate(output)}

      {:ok, %{stdout: output, exit_code: code}} ->
        {:ok, "Exit code #{code}:\n#{truncate(output)}"}

      {:error, :timeout} ->
        {:error, "Script timed out after #{@default_timeout}ms"}

      {:error, reason} ->
        {:error, "Script failed: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "Unknown executor type"}

  @doc "Convert a dynamic tool spec to OpenAI function-calling schema format."
  def to_schema(%{name: name, description: desc, parameters_schema: params}) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => desc,
        "parameters" => params
      }
    }
  end

  defp interpolate(template, args) do
    Enum.reduce(args, template, fn {key, value}, acc ->
      String.replace(acc, "${#{key}}", shell_escape(to_string(value)))
    end)
  end

  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp truncate(output) do
    if String.length(output) > @max_output do
      String.slice(output, 0, @max_output) <> "\n... (truncated)"
    else
      output
    end
  end
end
