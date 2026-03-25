defmodule Traitee.Tools.TaskTrackerTest do
  use ExUnit.Case, async: true

  alias Traitee.Tools.TaskTracker

  setup do
    session_id = "test_tt_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      Enum.each(TaskTracker.list_tasks(session_id), fn t ->
        :ets.delete(:traitee_task_tracker, {session_id, t.id})
      end)
    end)

    %{session_id: session_id}
  end

  describe "name/0 and description/0" do
    test "returns expected name" do
      assert TaskTracker.name() == "task_tracker"
    end

    test "returns non-empty description" do
      assert is_binary(TaskTracker.description())
      assert TaskTracker.description() != ""
    end
  end

  describe "add action" do
    test "adds a task with default pending status", %{session_id: sid} do
      assert {:ok, msg} =
               TaskTracker.execute(%{
                 "action" => "add",
                 "id" => "write-tests",
                 "content" => "Write unit tests",
                 "_session_id" => sid
               })

      assert msg =~ "Task added"
      assert msg =~ "pending"
      assert msg =~ "write-tests"
    end

    test "adds a task with explicit status", %{session_id: sid} do
      assert {:ok, msg} =
               TaskTracker.execute(%{
                 "action" => "add",
                 "id" => "fix-bug",
                 "content" => "Fix the crash",
                 "status" => "in_progress",
                 "_session_id" => sid
               })

      assert msg =~ "in_progress"
    end

    test "rejects invalid status", %{session_id: sid} do
      assert {:error, msg} =
               TaskTracker.execute(%{
                 "action" => "add",
                 "id" => "bad",
                 "content" => "Bad task",
                 "status" => "invalid",
                 "_session_id" => sid
               })

      assert msg =~ "Invalid status"
    end

    test "requires id and content" do
      assert {:error, _} = TaskTracker.execute(%{"action" => "add"})
    end

    test "overwrites existing task with same id", %{session_id: sid} do
      base = %{"action" => "add", "id" => "t1", "_session_id" => sid}

      TaskTracker.execute(Map.merge(base, %{"content" => "Original"}))
      TaskTracker.execute(Map.merge(base, %{"content" => "Updated"}))

      tasks = TaskTracker.list_tasks(sid)
      assert length(tasks) == 1
      assert hd(tasks).content == "Updated"
    end
  end

  describe "update action" do
    test "updates task status", %{session_id: sid} do
      TaskTracker.execute(%{
        "action" => "add",
        "id" => "t1",
        "content" => "Do stuff",
        "_session_id" => sid
      })

      assert {:ok, msg} =
               TaskTracker.execute(%{
                 "action" => "update",
                 "id" => "t1",
                 "status" => "completed",
                 "_session_id" => sid
               })

      assert msg =~ "completed"
    end

    test "returns error for nonexistent task", %{session_id: sid} do
      assert {:error, msg} =
               TaskTracker.execute(%{
                 "action" => "update",
                 "id" => "nope",
                 "status" => "completed",
                 "_session_id" => sid
               })

      assert msg =~ "not found"
    end

    test "requires id and status" do
      assert {:error, _} = TaskTracker.execute(%{"action" => "update"})
    end
  end

  describe "list action" do
    test "returns empty when no tasks", %{session_id: sid} do
      assert {:ok, "No tasks."} =
               TaskTracker.execute(%{"action" => "list", "_session_id" => sid})
    end

    test "lists all tasks", %{session_id: sid} do
      for i <- 1..3 do
        TaskTracker.execute(%{
          "action" => "add",
          "id" => "t#{i}",
          "content" => "Task #{i}",
          "_session_id" => sid
        })
      end

      assert {:ok, msg} = TaskTracker.execute(%{"action" => "list", "_session_id" => sid})
      assert msg =~ "t1"
      assert msg =~ "t2"
      assert msg =~ "t3"
    end
  end

  describe "clear action" do
    test "removes completed and cancelled tasks", %{session_id: sid} do
      base = %{"action" => "add", "_session_id" => sid}

      TaskTracker.execute(
        Map.merge(base, %{"id" => "done", "content" => "Done", "status" => "completed"})
      )

      TaskTracker.execute(
        Map.merge(base, %{"id" => "nope", "content" => "Nope", "status" => "cancelled"})
      )

      TaskTracker.execute(
        Map.merge(base, %{"id" => "wip", "content" => "WIP", "status" => "in_progress"})
      )

      assert {:ok, msg} = TaskTracker.execute(%{"action" => "clear", "_session_id" => sid})
      assert msg =~ "2"

      remaining = TaskTracker.list_tasks(sid)
      assert length(remaining) == 1
      assert hd(remaining).id == "wip"
    end
  end

  describe "active_tasks/1" do
    test "returns only pending and in_progress, sorted", %{session_id: sid} do
      base = %{"action" => "add", "_session_id" => sid}

      TaskTracker.execute(
        Map.merge(base, %{"id" => "a", "content" => "A", "status" => "pending"})
      )

      TaskTracker.execute(
        Map.merge(base, %{"id" => "b", "content" => "B", "status" => "in_progress"})
      )

      TaskTracker.execute(
        Map.merge(base, %{"id" => "c", "content" => "C", "status" => "completed"})
      )

      active = TaskTracker.active_tasks(sid)
      assert length(active) == 2
      assert hd(active).status == "in_progress"
    end
  end

  describe "session isolation" do
    test "tasks are scoped per session" do
      s1 = "iso_#{:erlang.unique_integer([:positive])}"
      s2 = "iso_#{:erlang.unique_integer([:positive])}"

      TaskTracker.execute(%{
        "action" => "add",
        "id" => "t1",
        "content" => "A",
        "_session_id" => s1
      })

      TaskTracker.execute(%{
        "action" => "add",
        "id" => "t1",
        "content" => "B",
        "_session_id" => s2
      })

      assert length(TaskTracker.list_tasks(s1)) == 1
      assert length(TaskTracker.list_tasks(s2)) == 1
      assert hd(TaskTracker.list_tasks(s1)).content == "A"
      assert hd(TaskTracker.list_tasks(s2)).content == "B"

      :ets.delete(:traitee_task_tracker, {s1, "t1"})
      :ets.delete(:traitee_task_tracker, {s2, "t1"})
    end
  end

  describe "unknown/missing actions" do
    test "unknown action returns error" do
      assert {:error, msg} = TaskTracker.execute(%{"action" => "destroy"})
      assert msg =~ "Unknown action"
    end

    test "missing action returns error" do
      assert {:error, _} = TaskTracker.execute(%{})
    end
  end
end
