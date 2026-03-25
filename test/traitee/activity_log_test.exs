defmodule Traitee.ActivityLogTest do
  use ExUnit.Case, async: true

  alias Traitee.ActivityLog

  setup do
    session_id = "test_al_#{:erlang.unique_integer([:positive])}"
    %{session_id: session_id}
  end

  describe "record/3" do
    test "records an event and returns :ok", %{session_id: sid} do
      assert :ok = ActivityLog.record(sid, :tool_call, %{name: "bash", status: :ok})
    end

    test "records multiple events", %{session_id: sid} do
      for i <- 1..5 do
        ActivityLog.record(sid, :tool_call, %{name: "tool_#{i}"})
      end

      entries = ActivityLog.recent(sid, 10)
      assert length(entries) == 5
    end

    test "preserves event details", %{session_id: sid} do
      ActivityLog.record(sid, :tool_call, %{name: "bash", status: :ok, duration_ms: 42})

      [entry] = ActivityLog.recent(sid, 1)
      assert entry.event_type == :tool_call
      assert entry.details.name == "bash"
      assert entry.details.duration_ms == 42
    end

    test "assigns incrementing ids", %{session_id: sid} do
      ActivityLog.record(sid, :tool_call, %{name: "a"})
      ActivityLog.record(sid, :tool_call, %{name: "b"})

      [later, earlier] = ActivityLog.recent(sid, 2)
      assert later.id > earlier.id
    end
  end

  describe "recent/2" do
    test "returns empty list for unknown session" do
      assert [] == ActivityLog.recent("nonexistent_#{:erlang.unique_integer([:positive])}")
    end

    test "respects limit", %{session_id: sid} do
      for _ <- 1..10, do: ActivityLog.record(sid, :llm_call, %{})

      assert length(ActivityLog.recent(sid, 3)) == 3
    end

    test "returns most recent entries first", %{session_id: sid} do
      ActivityLog.record(sid, :tool_call, %{name: "first"})
      ActivityLog.record(sid, :tool_call, %{name: "second"})

      [latest | _] = ActivityLog.recent(sid, 2)
      assert latest.details.name == "second"
    end
  end

  describe "summary/1" do
    test "returns zero counts for empty session" do
      summary = ActivityLog.summary("empty_#{:erlang.unique_integer([:positive])}")
      assert summary.total_events == 0
      assert summary.tool_calls == 0
      assert summary.llm_calls == 0
    end

    test "aggregates tool call counts", %{session_id: sid} do
      ActivityLog.record(sid, :tool_call, %{name: "bash"})
      ActivityLog.record(sid, :tool_call, %{name: "bash"})
      ActivityLog.record(sid, :tool_call, %{name: "file"})
      ActivityLog.record(sid, :llm_call, %{latency_ms: 100})

      summary = ActivityLog.summary(sid)
      assert summary.total_events == 4
      assert summary.tool_calls == 3
      assert summary.tool_counts["bash"] == 2
      assert summary.tool_counts["file"] == 1
      assert summary.llm_calls == 1
      assert summary.avg_llm_latency_ms == 100
    end

    test "computes average LLM latency", %{session_id: sid} do
      ActivityLog.record(sid, :llm_call, %{latency_ms: 200})
      ActivityLog.record(sid, :llm_call, %{latency_ms: 400})

      summary = ActivityLog.summary(sid)
      assert summary.avg_llm_latency_ms == 300
    end
  end

  describe "session isolation" do
    test "events are scoped per session" do
      s1 = "iso_al_#{:erlang.unique_integer([:positive])}"
      s2 = "iso_al_#{:erlang.unique_integer([:positive])}"

      ActivityLog.record(s1, :tool_call, %{name: "a"})
      ActivityLog.record(s1, :tool_call, %{name: "b"})
      ActivityLog.record(s2, :tool_call, %{name: "c"})

      assert length(ActivityLog.recent(s1, 100)) == 2
      assert length(ActivityLog.recent(s2, 100)) == 1
    end
  end

  describe "event types" do
    test "supports all documented event types", %{session_id: sid} do
      assert :ok = ActivityLog.record(sid, :tool_call, %{name: "bash"})
      assert :ok = ActivityLog.record(sid, :llm_call, %{model: "gpt-4o"})
      assert :ok = ActivityLog.record(sid, :subagent_dispatch, %{tags: ["research"]})

      assert :ok =
               ActivityLog.record(sid, :subagent_complete, %{tag: "research", status: :completed})

      assert :ok = ActivityLog.record(sid, :session_event, %{event: :start})

      entries = ActivityLog.recent(sid, 10)
      types = Enum.map(entries, & &1.event_type) |> MapSet.new()

      assert :tool_call in types
      assert :llm_call in types
      assert :subagent_dispatch in types
      assert :subagent_complete in types
      assert :session_event in types
    end
  end
end
