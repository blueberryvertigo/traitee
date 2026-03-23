defmodule Traitee.Tools.SkillManage do
  @moduledoc """
  Self-improvement tool — lets the LLM create, update, patch, and delete
  its own skills. Skills are the agent's procedural memory: reusable
  approaches for recurring task types.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Skills.Loader

  @impl true
  def name, do: "skill_manage"

  @impl true
  def description do
    """
    Manage your own skills (procedural memory). Create skills after \
    completing complex tasks, patch them when you find improvements, \
    delete skills that are no longer useful. Use 'list' to see all skills.\
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["create", "patch", "edit", "delete", "list"],
          "description" =>
            "create: new skill, patch: targeted substring fix (preferred for updates), edit: full body rewrite, delete: remove skill, list: show all"
        },
        "name" => %{
          "type" => "string",
          "description" =>
            "Skill name (lowercase, hyphens). Required for create/patch/edit/delete."
        },
        "description" => %{
          "type" => "string",
          "description" =>
            "One-line description (used for keyword matching). Required for create."
        },
        "content" => %{
          "type" => "string",
          "description" =>
            "Full SKILL.md body (markdown, no frontmatter). Required for create and edit."
        },
        "old_string" => %{
          "type" => "string",
          "description" => "Substring to find (for patch action). Must be unique in the file."
        },
        "new_string" => %{
          "type" => "string",
          "description" => "Replacement string (for patch action)."
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "create", "name" => name, "content" => content} = args)
      when is_binary(name) and is_binary(content) do
    description = args["description"] || ""
    meta = %{description: description}
    Loader.create_skill(name, meta, content)
  end

  def execute(%{"action" => "create"}) do
    {:error, "Missing required parameters: name, content"}
  end

  def execute(%{"action" => "patch", "name" => name, "old_string" => old, "new_string" => new})
      when is_binary(name) and is_binary(old) and is_binary(new) do
    Loader.patch_skill(name, old, new)
  end

  def execute(%{"action" => "patch"}) do
    {:error, "Missing required parameters: name, old_string, new_string"}
  end

  def execute(%{"action" => "edit", "name" => name, "content" => content})
      when is_binary(name) and is_binary(content) do
    Loader.update_skill(name, content)
  end

  def execute(%{"action" => "edit"}) do
    {:error, "Missing required parameters: name, content"}
  end

  def execute(%{"action" => "delete", "name" => name}) when is_binary(name) do
    Loader.delete_skill(name)
  end

  def execute(%{"action" => "delete"}) do
    {:error, "Missing required parameter: name"}
  end

  def execute(%{"action" => "list"}) do
    skills = Loader.scan()

    if skills == [] do
      {:ok, "No skills installed."}
    else
      lines =
        Enum.map(skills, fn s ->
          status = if s.enabled, do: "enabled", else: "disabled"
          "  #{s.name} (#{status}) — #{s.description}"
        end)

      {:ok, "Skills:\n#{Enum.join(lines, "\n")}"}
    end
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Supported: create, patch, edit, delete, list"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}
end
