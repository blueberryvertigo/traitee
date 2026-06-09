defmodule Traitee.Session.InterSessionTest do
  use ExUnit.Case, async: false

  alias Traitee.Session.InterSession

  describe "get_history/3" do
    test "rejects querying the caller's own session by session id" do
      sid = "is_own_#{:erlang.unique_integer([:positive])}"

      assert {:error, :cannot_query_own_session} =
               InterSession.get_history(sid, 20, current_session_id: sid)
    end

    test "returns :session_not_found for unknown session" do
      sid = "is_missing_#{:erlang.unique_integer([:positive])}"
      assert {:error, :session_not_found} = InterSession.get_history(sid)
    end

    test "reads the target session's STM table directly (no GenServer call)" do
      sid = "is_hist_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.register(Traitee.Session.Registry, sid, nil)

      # Mirror the STM table layout: named public ordered_set keyed by counter.
      table = :"traitee_stm_#{sid}"
      :ets.new(table, [:ordered_set, :named_table, :public])
      :ets.insert(table, {0, %{role: "user", content: "hello"}})
      :ets.insert(table, {1, %{role: "assistant", content: "hi there"}})

      assert {:ok, messages} = InterSession.get_history(sid, 10, current_session_id: "other")
      assert Enum.map(messages, & &1.content) == ["hello", "hi there"]
    end

    test "registered session without an STM table reports :session_not_found" do
      sid = "is_no_table_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.register(Traitee.Session.Registry, sid, nil)

      assert {:error, :session_not_found} =
               InterSession.get_history(sid, 10, current_session_id: "other")
    end
  end

  describe "send_to_session/4" do
    test "rejects sending to the same session id" do
      sid = "is_self_#{:erlang.unique_integer([:positive])}"

      assert {:error, :cannot_message_own_session} =
               InterSession.send_to_session(sid, sid, "hi")
    end

    test "enforces the hop limit" do
      assert {:error, :inter_session_hop_limit} =
               InterSession.send_to_session("a", "b", "hi", hop: 2)
    end

    test "returns :session_not_found for unknown target" do
      target = "is_target_missing_#{:erlang.unique_integer([:positive])}"

      assert {:error, :session_not_found} =
               InterSession.send_to_session("a", target, "hi")
    end
  end
end
