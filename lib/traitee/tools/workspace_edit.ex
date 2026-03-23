defmodule Traitee.Tools.WorkspaceEdit do
  @moduledoc """
  Self-improvement tool — lets the LLM read and modify its own
  workspace prompt files (SOUL.md, AGENTS.md, TOOLS.md).

  Changes take effect on the next session. A .bak backup is created
  before every write. Files are capped at 8,000 characters to keep
  the system prompt bounded.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Workspace

  @allowed_files %{
    "soul" => :soul,
    "agents" => :agents,
    "tools" => :tools
  }

  @impl true
  def name, do: "workspace_edit"

  @impl true
  def description do
    """
    Read and modify your own identity and instruction files (SOUL.md, \
    AGENTS.md, TOOLS.md). Use 'read' to see current content, 'patch' for \
    targeted edits, 'append' to add new sections. Changes take effect next session.\
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["read", "patch", "append"],
          "description" => "read: view file, patch: substring replacement, append: add to end"
        },
        "file" => %{
          "type" => "string",
          "enum" => ["soul", "agents", "tools"],
          "description" =>
            "Which workspace file: soul (SOUL.md), agents (AGENTS.md), tools (TOOLS.md)"
        },
        "old_string" => %{
          "type" => "string",
          "description" => "Substring to find (for patch). Must be unique in the file."
        },
        "new_string" => %{
          "type" => "string",
          "description" => "Replacement string (for patch)."
        },
        "content" => %{
          "type" => "string",
          "description" => "Content to append (for append action)."
        }
      },
      "required" => ["action", "file"]
    }
  end

  @impl true
  def execute(%{"action" => "read", "file" => file}) do
    with {:ok, key} <- resolve_file(file) do
      case Workspace.read_raw(key) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:ok, "(File is empty or does not exist)"}
        {:error, reason} -> {:error, "Failed to read: #{reason}"}
      end
    end
  end

  def execute(%{"action" => "patch", "file" => file, "old_string" => old, "new_string" => new})
      when is_binary(old) and is_binary(new) do
    with {:ok, key} <- resolve_file(file) do
      Workspace.patch_file(key, old, new)
    end
  end

  def execute(%{"action" => "patch"}) do
    {:error, "Missing required parameters: file, old_string, new_string"}
  end

  def execute(%{"action" => "append", "file" => file, "content" => content})
      when is_binary(content) do
    with {:ok, key} <- resolve_file(file) do
      Workspace.append_to_file(key, content)
    end
  end

  def execute(%{"action" => "append"}) do
    {:error, "Missing required parameters: file, content"}
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Supported: read, patch, append"}
  end

  def execute(_), do: {:error, "Missing required parameters: action, file"}

  defp resolve_file(file) when is_binary(file) do
    case Map.get(@allowed_files, file) do
      nil -> {:error, "Invalid file: #{file}. Must be one of: soul, agents, tools"}
      key -> {:ok, key}
    end
  end
end
