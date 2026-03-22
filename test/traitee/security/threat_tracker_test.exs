defmodule Traitee.Security.ThreatTrackerTest do
  use ExUnit.Case, async: false

  alias Traitee.Security.Sanitizer.Threat
  alias Traitee.Security.ThreatTracker

  setup do
    ThreatTracker.init()
    session = "test-#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> ThreatTracker.clear(session) end)
    %{session: session}
  end

  test "starts at normal threat level", %{session: session} do
    assert ThreatTracker.threat_level(session) == :normal
    assert ThreatTracker.threat_score(session) == 0.0
  end

  test "records threats and increases score", %{session: session} do
    threat = %Threat{
      category: :instruction_override,
      severity: :critical,
      pattern_name: "test",
      matched_text: "test"
    }

    ThreatTracker.record(session, threat)

    assert ThreatTracker.threat_score(session) > 0
    assert ThreatTracker.event_count(session) == 1
  end

  test "critical threats push level to high or critical", %{session: session} do
    threat = %Threat{
      category: :instruction_override,
      severity: :critical,
      pattern_name: "test",
      matched_text: "test"
    }

    ThreatTracker.record(session, threat)
    ThreatTracker.record(session, threat)

    level = ThreatTracker.threat_level(session)
    assert level in [:high, :critical]
  end

  test "tracks categories seen", %{session: session} do
    t1 = %Threat{
      category: :instruction_override,
      severity: :critical,
      pattern_name: "a",
      matched_text: "a"
    }

    t2 = %Threat{category: :role_hijack, severity: :high, pattern_name: "b", matched_text: "b"}

    ThreatTracker.record(session, t1)
    ThreatTracker.record(session, t2)

    cats = ThreatTracker.categories_seen(session)
    assert :instruction_override in cats
    assert :role_hijack in cats
  end

  test "clear resets session", %{session: session} do
    threat = %Threat{
      category: :tag_injection,
      severity: :high,
      pattern_name: "test",
      matched_text: "test"
    }

    ThreatTracker.record(session, threat)
    ThreatTracker.clear(session)

    assert ThreatTracker.event_count(session) == 0
    assert ThreatTracker.threat_level(session) == :normal
  end

  test "summary returns formatted string", %{session: session} do
    threat = %Threat{
      category: :encoding_evasion,
      severity: :low,
      pattern_name: "test",
      matched_text: "test"
    }

    ThreatTracker.record(session, threat)

    summary = ThreatTracker.summary(session)
    assert String.contains?(summary, "threat_level=")
    assert String.contains?(summary, "encoding_evasion")
  end
end
