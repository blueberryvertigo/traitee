defmodule Traitee.Tools.File do
  @moduledoc """
  File system operations tool with sandbox enforcement.
  All operations are validated against `Traitee.Security.Sandbox` before execution.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Security.Sandbox

  @max_read 50_000

  @impl true
  def name, do: "file"

  @impl true
  def description do
    "Read, write, or list files. Operations: read, write, append, list, exists."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => ["read", "write", "append", "list", "exists"],
          "description" => "The file operation to perform"
        },
        "path" => %{
          "type" => "string",
          "description" => "File or directory path"
        },
        "content" => %{
          "type" => "string",
          "description" => "Content to write (for write/append operations)"
        }
      },
      "required" => ["operation", "path"]
    }
  end

  @impl true
  def execute(%{"operation" => op, "path" => path} = args) do
    path = Path.expand(path)
    operation = classify_operation(op)

    with :ok <- Sandbox.check_path(path, operation: operation) do
      case op do
        "read" -> read_file(path)
        "write" -> write_file(path, args["content"] || "")
        "append" -> append_file(path, args["content"] || "")
        "list" -> list_dir(path)
        "exists" -> {:ok, "#{File.exists?(path)}"}
        _ -> {:error, "Unknown operation: #{op}"}
      end
    end
  end

  def execute(_), do: {:error, "Missing required parameters: operation, path"}

  defp classify_operation(op) when op in ["write", "append"], do: :write
  defp classify_operation(_), do: :read

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        if String.length(content) > @max_read do
          {:ok, String.slice(content, 0, @max_read) <> "\n... (truncated)"}
        else
          {:ok, content}
        end

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok -> {:ok, "Written #{String.length(content)} bytes to #{path}"}
      {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
    end
  end

  defp append_file(path, content) do
    case File.write(path, content, [:append]) do
      :ok -> {:ok, "Appended #{String.length(content)} bytes to #{path}"}
      {:error, reason} -> {:error, "Cannot append to #{path}: #{reason}"}
    end
  end

  defp list_dir(path) do
    case File.ls(path) do
      {:ok, entries} ->
        listing =
          entries
          |> Enum.sort()
          |> Enum.map_join("\n", fn entry ->
            full = Path.join(path, entry)
            type = if File.dir?(full), do: "dir", else: "file"
            "#{type} #{entry}"
          end)

        {:ok, listing}

      {:error, reason} ->
        {:error, "Cannot list #{path}: #{reason}"}
    end
  end
end
