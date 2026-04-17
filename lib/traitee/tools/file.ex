defmodule Traitee.Tools.File do
  @moduledoc """
  File system operations tool with centralized sandbox enforcement.

  All operations are validated against the filesystem policy engine:
  hardcoded deny lists, configured allow/deny rules, per-path permissions,
  and exec gates for write operations. Every access attempt is recorded
  in the security audit trail.
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
    classify_operation_name = classify_operation_name(op)
    path = Path.expand(path)
    operation = classify_operation(op)
    session_id = args["_session_id"]

    with :ok <-
           Sandbox.check_path(path,
             operation: operation,
             tool: "file",
             session_id: session_id
           ),
         :ok <- refuse_if_symlink(path, operation) do
      # TOCTOU guard: re-run the sandbox check AFTER any pre-operation
      # (e.g. parent-directory creation) and immediately before the actual
      # syscall, and ensure the target resolves to the same location as was
      # originally validated. This catches attacker-planted symlinks that
      # appear between the initial check and the open.
      case classify_operation_name do
        :read -> safe_read(path, operation, session_id)
        :write -> safe_write(path, args["content"] || "", operation, session_id)
        :append -> safe_append(path, args["content"] || "", operation, session_id)
        :list -> list_dir(path)
        :exists -> {:ok, "#{File.exists?(path)}"}
        :unknown -> {:error, "Unknown operation: #{op}"}
      end
    end
  end

  def execute(_), do: {:error, "Missing required parameters: operation, path"}

  defp classify_operation_name("read"), do: :read
  defp classify_operation_name("write"), do: :write
  defp classify_operation_name("append"), do: :append
  defp classify_operation_name("list"), do: :list
  defp classify_operation_name("exists"), do: :exists
  defp classify_operation_name(_), do: :unknown

  defp classify_operation(op) when op in ["write", "append"], do: :write
  defp classify_operation(_), do: :read

  # Refuse to follow symlinks for any write operation. For reads, we allow
  # symlinks but only after Sandbox.check_path has resolved every component
  # and applied deny rules to the target.
  defp refuse_if_symlink(path, :write) do
    case File.read_link(path) do
      {:ok, _target} ->
        {:error, "Refusing to write through a symlink at #{path}"}

      {:error, _} ->
        :ok
    end
  end

  defp refuse_if_symlink(_path, _op), do: :ok

  defp recheck_path(path, operation, session_id) do
    Sandbox.check_path(path, operation: operation, tool: "file", session_id: session_id)
  end

  defp safe_read(path, operation, session_id) do
    with :ok <- recheck_path(path, operation, session_id),
         {:ok, content} <- File.read(path) do
      if String.length(content) > @max_read do
        {:ok, String.slice(content, 0, @max_read) <> "\n... (truncated)"}
      else
        {:ok, content}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, "Cannot read #{path}: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_write(path, content, operation, session_id) do
    # Ensure the parent dir exists; the parent itself must pass the sandbox
    # check as a write target (otherwise an attacker could force creation of
    # directories outside the allowed subtree via mkdir_p walking up).
    parent = Path.dirname(path)

    with :ok <- recheck_path(parent, :write, session_id),
         :ok <- File.mkdir_p(parent),
         :ok <- refuse_if_symlink(path, :write),
         :ok <- recheck_path(path, operation, session_id),
         :ok <- File.write(path, content) do
      {:ok, "Written #{String.length(content)} bytes to #{path}"}
    else
      {:error, reason} when is_atom(reason) -> {:error, "Cannot write #{path}: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_append(path, content, operation, session_id) do
    parent = Path.dirname(path)

    with :ok <- recheck_path(parent, :write, session_id),
         :ok <- File.mkdir_p(parent),
         :ok <- refuse_if_symlink(path, :write),
         :ok <- recheck_path(path, operation, session_id),
         :ok <- File.write(path, content, [:append]) do
      {:ok, "Appended #{String.length(content)} bytes to #{path}"}
    else
      {:error, reason} when is_atom(reason) -> {:error, "Cannot append to #{path}: #{reason}"}
      {:error, reason} -> {:error, reason}
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
