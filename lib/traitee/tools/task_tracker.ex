defmodule Traitee.Tools.TaskTracker do
  @moduledoc """
  Task tracking tool — lets the LLM self-organize with structured todos.
  Backed by ETS for fast reads (context injection) with async SQLite persistence.
  Scoped per session so each conversation has its own task list.
  """

  @behaviour Traitee.Tools.Tool

  require Logger

  @table :traitee_task_tracker

  @valid_statuses ~w(pending in_progress completed cancelled)

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :bag, :public, read_concurrency: true])
    end

    :ok
  end

  @impl true
  def name, do: "task_tracker"

  @impl true
  def description do
    """
    Manage a structured task list for the current session. Use this to organize \
    complex multi-step work. Actions: add (create a task), update (change status), \
    list (show active tasks), clear (remove completed/cancelled). \
    Statuses: pending, in_progress, completed, cancelled. \
    Keep only one task in_progress at a time. Mark tasks complete immediately when done.\
    """
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["add", "update", "list", "clear"],
          "description" => "Action to perform on the task list"
        },
        "id" => %{
          "type" => "string",
          "description" =>
            "Unique task ID (for add/update). Use short kebab-case, e.g. 'fix-bridge'"
        },
        "content" => %{
          "type" => "string",
          "description" => "Task description (for add)"
        },
        "status" => %{
          "type" => "string",
          "enum" => @valid_statuses,
          "description" => "Task status (for add/update). Default: pending"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "add", "id" => id, "content" => content} = args)
      when is_binary(id) and is_binary(content) do
    session_id = args["_session_id"] || "unknown"
    status = args["status"] || "pending"

    if status in @valid_statuses do
      now = DateTime.utc_now()

      task = %{
        id: id,
        content: content,
        status: status,
        session_id: session_id,
        created_at: now,
        updated_at: now
      }

      delete_task(session_id, id)
      :ets.insert(@table, {{session_id, id}, task})

      {:ok, "Task added: [#{status}] #{id} — #{content}"}
    else
      {:error, "Invalid status: #{status}. Must be one of: #{Enum.join(@valid_statuses, ", ")}"}
    end
  end

  def execute(%{"action" => "add"}) do
    {:error, "Missing required parameters: id, content"}
  end

  def execute(%{"action" => "update", "id" => id, "status" => status} = args)
      when is_binary(id) and is_binary(status) do
    session_id = args["_session_id"] || "unknown"

    if status in @valid_statuses do
      case get_task(session_id, id) do
        nil ->
          {:error, "Task not found: #{id}"}

        task ->
          updated = %{task | status: status, updated_at: DateTime.utc_now()}
          delete_task(session_id, id)
          :ets.insert(@table, {{session_id, id}, updated})

          {:ok, "Task updated: [#{status}] #{id} — #{task.content}"}
      end
    else
      {:error, "Invalid status: #{status}. Must be one of: #{Enum.join(@valid_statuses, ", ")}"}
    end
  end

  def execute(%{"action" => "update"}) do
    {:error, "Missing required parameters: id, status"}
  end

  def execute(%{"action" => "list"} = args) do
    session_id = args["_session_id"] || "unknown"
    tasks = list_tasks(session_id)

    if tasks == [] do
      {:ok, "No tasks."}
    else
      lines =
        tasks
        |> Enum.sort_by(& &1.created_at)
        |> Enum.map(fn t -> "  [#{t.status}] #{t.id} — #{t.content}" end)

      {:ok, "Tasks:\n#{Enum.join(lines, "\n")}"}
    end
  end

  def execute(%{"action" => "clear"} = args) do
    session_id = args["_session_id"] || "unknown"
    tasks = list_tasks(session_id)

    cleared =
      Enum.filter(tasks, fn t -> t.status in ["completed", "cancelled"] end)

    Enum.each(cleared, fn t -> delete_task(session_id, t.id) end)

    {:ok, "Cleared #{length(cleared)} completed/cancelled task(s)."}
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Supported: add, update, list, clear"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  @doc "Returns active (non-completed, non-cancelled) tasks for a session. Used by context engine."
  def active_tasks(session_id) do
    auto_prune(session_id)

    list_tasks(session_id)
    |> Enum.filter(fn t -> t.status in ["pending", "in_progress"] end)
    |> Enum.sort_by(fn t ->
      case t.status do
        "in_progress" -> 0
        "pending" -> 1
      end
    end)
  end

  @doc """
  Returns a compact one-line-per-task summary for injection between tool rounds.
  Returns nil when there are no active tasks.
  """
  def compact_summary(session_id) do
    tasks = active_tasks(session_id)

    if tasks == [] do
      nil
    else
      lines = Enum.map(tasks, fn t -> "[#{t.status}] #{t.id}: #{t.content}" end)
      "[Active Tasks] " <> Enum.join(lines, " | ")
    end
  end

  @doc "Returns all tasks for a session."
  def list_tasks(session_id) do
    if :ets.whereis(@table) != :undefined do
      :ets.match_object(@table, {{session_id, :_}, :_})
      |> Enum.map(fn {_key, task} -> task end)
    else
      []
    end
  end

  @max_completed_age_ms 10 * 60 * 1_000

  @doc "Removes completed/cancelled tasks older than 10 minutes."
  def auto_prune(session_id) do
    now = DateTime.utc_now()

    list_tasks(session_id)
    |> Enum.filter(fn t -> t.status in ["completed", "cancelled"] end)
    |> Enum.each(fn t ->
      age_ms = DateTime.diff(now, t.updated_at, :millisecond)

      if age_ms > @max_completed_age_ms do
        delete_task(session_id, t.id)
      end
    end)
  rescue
    _ -> :ok
  end

  defp get_task(session_id, id) do
    case :ets.lookup(@table, {session_id, id}) do
      [{_key, task}] -> task
      _ -> nil
    end
  end

  defp delete_task(session_id, id) do
    :ets.delete(@table, {session_id, id})
  end
end
