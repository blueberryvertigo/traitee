defmodule Traitee.Tools.Dynamic do
  @moduledoc """
  Execution engine for dynamically registered script-based tools.

  Now routes all execution through the centralized sandbox — command
  validation, filesystem policy, exec gates, environment scrubbing,
  and Docker isolation are enforced for dynamic tools just as for
  built-in tools.
  """

  alias Traitee.Process.Executor
  alias Traitee.Security.{Docker, Sandbox}

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
  def execute(%{executor: {:bash, template}, name: tool_name}, args) do
    command = interpolate(template, args)
    session_id = args["_session_id"]

    with :ok <-
           Sandbox.check_command(command, tool: "dynamic:#{tool_name}", session_id: session_id) do
      env = Sandbox.scrubbed_env()

      result =
        if Docker.enabled?() do
          case Docker.run(command, timeout_ms: @default_timeout, env: env, session_id: session_id) do
            {:ok, r} ->
              {:ok, r}

            {:error, {:docker_unavailable, _}} ->
              Executor.run(command, timeout_ms: @default_timeout, env: env)

            other ->
              other
          end
        else
          Executor.run(command, timeout_ms: @default_timeout, env: env)
        end

      format_tool_result(result)
    end
  end

  def execute(%{executor: {:script, path}, name: tool_name}, args) do
    session_id = args["_session_id"]

    with :ok <-
           Sandbox.check_path(path,
             operation: :exec,
             tool: "dynamic:#{tool_name}",
             session_id: session_id
           ) do
      command = build_script_command(path, args)

      with :ok <-
             Sandbox.check_command(command, tool: "dynamic:#{tool_name}", session_id: session_id) do
        run_with_sandbox(command, session_id)
        |> format_script_result()
      end
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

  defp build_script_command(path, args) do
    json_args = Jason.encode!(args)

    case Path.extname(path) do
      ".py" -> "echo #{shell_escape(json_args)} | python #{shell_escape(path)}"
      ".sh" -> "echo #{shell_escape(json_args)} | bash #{shell_escape(path)}"
      ".js" -> "echo #{shell_escape(json_args)} | node #{shell_escape(path)}"
      _ -> "echo #{shell_escape(json_args)} | #{shell_escape(path)}"
    end
  end

  defp run_with_sandbox(command, session_id) do
    env = Sandbox.scrubbed_env()

    if Docker.enabled?() do
      case Docker.run(command, timeout_ms: @default_timeout, env: env, session_id: session_id) do
        {:ok, r} ->
          {:ok, r}

        {:error, {:docker_unavailable, _}} ->
          Executor.run(command, timeout_ms: @default_timeout, env: env)

        other ->
          other
      end
    else
      Executor.run(command, timeout_ms: @default_timeout, env: env)
    end
  end

  defp format_tool_result({:ok, %{stdout: output, exit_code: 0}}), do: {:ok, truncate(output)}

  defp format_tool_result({:ok, %{stdout: output, exit_code: code}}),
    do: {:ok, "Exit code #{code}:\n#{truncate(output)}"}

  defp format_tool_result({:error, :timeout}),
    do: {:error, "Tool timed out after #{@default_timeout}ms"}

  defp format_tool_result({:error, reason}), do: {:error, "Tool failed: #{inspect(reason)}"}

  defp format_script_result({:ok, %{stdout: output, exit_code: 0}}), do: {:ok, truncate(output)}

  defp format_script_result({:ok, %{stdout: output, exit_code: code}}),
    do: {:ok, "Exit code #{code}:\n#{truncate(output)}"}

  defp format_script_result({:error, :timeout}),
    do: {:error, "Script timed out after #{@default_timeout}ms"}

  defp format_script_result({:error, reason}), do: {:error, "Script failed: #{inspect(reason)}"}

  defp interpolate(template, args) do
    Enum.reduce(args, template, fn
      {"_session_id", _}, acc ->
        acc

      {key, value}, acc ->
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
