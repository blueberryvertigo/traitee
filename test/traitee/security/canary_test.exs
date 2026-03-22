defmodule Traitee.Security.CanaryTest do
  use ExUnit.Case, async: false

  alias Traitee.Security.Canary

  setup do
    Canary.init()
    session = "test-#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> Canary.clear(session) end)
    %{session: session}
  end

  test "generates unique canary tokens", %{session: session} do
    token = Canary.generate(session)
    assert String.starts_with?(token, "CANARY-")
    assert String.length(token) == 19
  end

  test "get returns nil for unknown session" do
    assert Canary.get("nonexistent-session") == nil
  end

  test "get_or_create creates on first call", %{session: session} do
    token = Canary.get_or_create(session)
    assert token == Canary.get(session)
  end

  test "rotate changes the token", %{session: session} do
    token1 = Canary.generate(session)
    token2 = Canary.rotate(session)
    assert token1 != token2
    assert Canary.get(session) == token2
  end

  test "leaked? detects canary in text", %{session: session} do
    token = Canary.generate(session)
    assert Canary.leaked?(session, "here is #{token} in my response")
    refute Canary.leaked?(session, "normal response without canary")
  end

  test "system_prompt_section includes token", %{session: session} do
    section = Canary.system_prompt_section(session)
    token = Canary.get(session)
    assert String.contains?(section, token)
    assert String.contains?(section, "confidential")
  end

  test "clear removes token", %{session: session} do
    Canary.generate(session)
    Canary.clear(session)
    assert Canary.get(session) == nil
  end
end
