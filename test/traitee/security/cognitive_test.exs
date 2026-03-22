defmodule Traitee.Security.CognitiveTest do
  use ExUnit.Case, async: false

  alias Traitee.Security.{Canary, Cognitive, ThreatTracker}
  alias Traitee.Security.Sanitizer.Threat

  setup do
    ThreatTracker.init()
    Canary.init()
    session = "test-#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      ThreatTracker.clear(session)
      Canary.clear(session)
    end)

    %{session: session}
  end

  describe "reminders_for/2" do
    test "no reminders at message 1 with no threats", %{session: session} do
      reminders = Cognitive.reminders_for(session, message_count: 1)
      assert reminders == []
    end

    test "positional reminder at interval boundary", %{session: session} do
      reminders = Cognitive.reminders_for(session, message_count: 8)
      assert reminders != []
      assert hd(reminders).role == "system"
      assert String.contains?(hd(reminders).content, "[Cognitive Security]")
    end

    test "reactive reminder when threats detected", %{session: session} do
      reminders = Cognitive.reminders_for(session, message_count: 3, has_recent_threats: true)
      assert reminders != []
      assert Enum.any?(reminders, &String.contains?(&1.content, "[Security Alert]"))
    end

    test "reminder intensity scales with threat level", %{session: session} do
      threat = %Threat{
        category: :instruction_override,
        severity: :critical,
        pattern_name: "t",
        matched_text: "t"
      }

      for _ <- 1..5, do: ThreatTracker.record(session, threat)

      reminders = Cognitive.reminders_for(session, message_count: 8)
      assert reminders != []
      content = hd(reminders).content
      assert String.contains?(content, "CRITICAL") or String.contains?(content, "IMPORTANT")
    end

    test "caps at 2 reminders max", %{session: session} do
      threat = %Threat{
        category: :role_hijack,
        severity: :high,
        pattern_name: "t",
        matched_text: "t"
      }

      ThreatTracker.record(session, threat)

      reminders = Cognitive.reminders_for(session, message_count: 8, has_recent_threats: true)
      assert length(reminders) <= 2
    end
  end

  describe "tool_reminder/0" do
    test "returns a system message about tool safety" do
      reminder = Cognitive.tool_reminder()
      assert reminder.role == "system"
      assert String.contains?(reminder.content, "untrusted")
    end
  end
end
