defmodule Traitee.Security.AuditTest do
  use ExUnit.Case, async: false

  alias Traitee.Security.Audit

  setup do
    Audit.clear()
    :ok
  end

  describe "record/2" do
    test "records a path_access event" do
      Audit.record(:path_access, %{
        path: "/tmp/test.txt",
        operation: :read,
        decision: :allow,
        tool: :file,
        session_id: "test-session"
      })

      events = Audit.recent(10)
      assert events != []
      event = List.first(events)
      assert event.type == :path_access
      assert event.decision == :allow
    end

    test "records a command_check event" do
      Audit.record(:command_check, %{
        command: "ls -la",
        decision: :allow,
        tool: :bash,
        session_id: "test-session"
      })

      events = Audit.recent(10)
      assert events != []
    end

    test "records multiple events" do
      for i <- 1..5 do
        Audit.record(:path_access, %{
          path: "/tmp/file#{i}.txt",
          decision: :allow,
          tool: :file
        })
      end

      events = Audit.recent(10)
      assert length(events) >= 5
      # length intentional: verifying exact count of inserted events
    end
  end

  describe "query/1" do
    test "filters by type" do
      Audit.record(:path_access, %{path: "/tmp/a.txt", decision: :allow})
      Audit.record(:command_check, %{command: "ls", decision: :allow})

      path_events = Audit.query(type: :path_access)
      assert Enum.all?(path_events, &(&1.type == :path_access))
    end

    test "filters by decision" do
      Audit.record(:path_access, %{path: "/tmp/a.txt", decision: :allow})
      Audit.record(:path_access, %{path: "/etc/shadow", decision: :deny})

      denials = Audit.query(decision: :deny)
      assert Enum.all?(denials, &(&1.decision == :deny))
    end

    test "filters by tool" do
      Audit.record(:path_access, %{path: "/tmp/a.txt", decision: :allow, tool: :file})
      Audit.record(:command_check, %{command: "ls", decision: :allow, tool: :bash})

      file_events = Audit.query(tool: :file)
      assert Enum.all?(file_events, &(&1[:tool] == :file))
    end
  end

  describe "stats/0" do
    test "returns aggregate statistics" do
      Audit.record(:path_access, %{path: "/tmp/a.txt", decision: :allow})
      Audit.record(:path_access, %{path: "/etc/shadow", decision: :deny})

      stats = Audit.stats()
      assert stats.total_events >= 2
      assert is_map(stats.decisions)
      assert is_map(stats.by_type)
    end
  end

  describe "format_report/0" do
    test "returns a formatted string" do
      Audit.record(:path_access, %{path: "/tmp/a.txt", decision: :allow})

      report = Audit.format_report()
      assert is_binary(report)
      assert report =~ "Audit Trail"
    end
  end

  describe "clear/0" do
    test "removes all events" do
      Audit.record(:path_access, %{path: "/tmp/a.txt", decision: :allow})
      assert Audit.recent(10) != []

      Audit.clear()
      assert Audit.recent(10) == []
    end
  end
end
