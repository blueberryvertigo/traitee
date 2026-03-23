defmodule Traitee.Tools.DelegateTask do
  @moduledoc """
  Delegation tool — spawns isolated subagents to work on tasks in parallel.
  Each subagent gets its own conversation, tool subset, and completion loop.
  Only the final result enters the parent's context — intermediate tool
  calls never pollute the parent's token budget.

  Results are returned as XML-structured text with tags for identification.
  """

  @behaviour Traitee.Tools.Tool

  alias Traitee.Delegation.Runner

  @impl true
  def name, do: "delegate_task"

  @impl true
  def description do
    """
    Spawn subagents to work on tasks in parallel. Each subagent gets its \
    own isolated context and tool access. Only the final results are returned \
    as XML. Use this when you have independent subtasks that can run concurrently. \
    You must specify which tools each subagent can use.\
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "tasks" => %{
          "type" => "array",
          "description" => "List of tasks to delegate (max 5)",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "tag" => %{
                "type" => "string",
                "description" =>
                  "Unique identifier tag for this subagent (e.g. 'research', 'code-review')"
              },
              "description" => %{
                "type" => "string",
                "description" => "The task description for this subagent"
              },
              "tools" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "Tool names this subagent can use (e.g. ['bash', 'file', 'web_search'])"
              }
            },
            "required" => ["tag", "description", "tools"]
          }
        },
        "timeout" => %{
          "type" => "integer",
          "description" => "Per-subagent timeout in milliseconds (default: 60000, max: 120000)"
        },
        "system_prompt" => %{
          "type" => "string",
          "description" => "Optional override system prompt for all subagents"
        }
      },
      "required" => ["tasks"]
    }
  end

  @impl true
  def execute(%{"tasks" => tasks} = args) when is_list(tasks) and tasks != [] do
    parsed_tasks =
      Enum.map(tasks, fn task ->
        %{
          tag: task["tag"] || "unnamed",
          description: task["description"] || "",
          tools: task["tools"] || []
        }
      end)

    tags = Enum.map(parsed_tasks, & &1.tag)

    if length(tags) != length(Enum.uniq(tags)) do
      {:error, "Duplicate tags found — each subagent must have a unique tag"}
    else
      opts =
        [session_id: args["_session_id"]]
        |> maybe_put(:timeout, args["timeout"])
        |> maybe_put(:system_prompt, args["system_prompt"])

      Runner.run(parsed_tasks, opts)
    end
  end

  def execute(%{"tasks" => []}) do
    {:error, "Tasks list cannot be empty"}
  end

  def execute(_), do: {:error, "Missing required parameter: tasks (array of task objects)"}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
