defmodule Traitee.Tools.Tool do
  @moduledoc """
  Behaviour for tools that the AI assistant can invoke.

  Each tool implements this behaviour to define its name, description,
  parameter schema (JSON Schema format), and execution logic.
  The schemas are compiled into OpenAI function-calling format at startup.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters_schema() :: map()
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Converts a tool module into OpenAI function-calling schema format.
  """
  def to_schema(module) do
    %{
      "type" => "function",
      "function" => %{
        "name" => module.name(),
        "description" => module.description(),
        "parameters" => module.parameters_schema()
      }
    }
  end
end
