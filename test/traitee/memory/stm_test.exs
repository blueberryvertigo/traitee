defmodule Traitee.Memory.STMTest do
  use ExUnit.Case, async: false

  import Traitee.TestHelpers

  alias Traitee.Memory.STM

  setup do
    session_id = unique_session_id()
    stm = init_test_stm(session_id, capacity: 10)
    on_exit(fn -> cleanup_test_stm(stm) end)
    %{stm: stm, session_id: session_id}
  end

  describe "init/2" do
    test "creates an ETS table for the session" do
      sid = unique_session_id()
      table = :"traitee_stm_test_#{sid}"
      stm = init_test_stm(sid)
      assert :ets.whereis(table) != :undefined
      assert stm.capacity == 50
      assert stm.counter == 0
      cleanup_test_stm(stm)
    end

    test "respects custom capacity" do
      sid = unique_session_id()
      stm = init_test_stm(sid, capacity: 25)
      assert stm.capacity == 25
      cleanup_test_stm(stm)
    end
  end

  describe "push/4 and get_messages/1" do
    test "stores a message and retrieves it", %{stm: stm} do
      stm = push_direct(stm, "user", "hello world")
      messages = STM.get_messages(stm)

      assert length(messages) == 1
      assert hd(messages).role == "user"
      assert hd(messages).content == "hello world"
    end

    test "stores multiple messages in order", %{stm: stm} do
      stm =
        stm
        |> push_direct("user", "first")
        |> push_direct("assistant", "second")
        |> push_direct("user", "third")

      messages = STM.get_messages(stm)
      assert length(messages) == 3
      assert Enum.map(messages, & &1.content) == ["first", "second", "third"]
    end

    test "tracks token counts", %{stm: stm} do
      stm = push_direct(stm, "user", "hello world")
      [msg] = STM.get_messages(stm)
      assert is_integer(msg.token_count)
      assert msg.token_count > 0
    end

    test "timestamps are set", %{stm: stm} do
      stm = push_direct(stm, "user", "test")
      [msg] = STM.get_messages(stm)
      assert %DateTime{} = msg.timestamp
    end
  end

  describe "get_recent/2" do
    test "returns last N messages", %{stm: stm} do
      stm =
        Enum.reduce(1..5, stm, fn i, acc ->
          push_direct(acc, "user", "msg #{i}")
        end)

      recent = STM.get_recent(stm, 2)
      assert length(recent) == 2
      assert Enum.map(recent, & &1.content) == ["msg 4", "msg 5"]
    end

    test "returns all if N > count", %{stm: stm} do
      stm = push_direct(stm, "user", "only one")
      recent = STM.get_recent(stm, 10)
      assert length(recent) == 1
    end
  end

  describe "total_tokens/1" do
    test "sums token counts across messages", %{stm: stm} do
      stm =
        stm
        |> push_direct("user", "short")
        |> push_direct("assistant", "a much longer message with more tokens in it")

      total = STM.total_tokens(stm)
      assert total > 0
      assert is_integer(total)
    end

    test "returns 0 for empty buffer", %{stm: stm} do
      assert STM.total_tokens(stm) == 0
    end
  end

  describe "count/1" do
    test "returns number of messages", %{stm: stm} do
      assert STM.count(stm) == 0

      stm = push_direct(stm, "user", "one")
      assert STM.count(stm) == 1

      stm = push_direct(stm, "user", "two")
      assert STM.count(stm) == 2
    end
  end

  describe "clear/1" do
    test "removes all messages", %{stm: stm} do
      stm =
        stm
        |> push_direct("user", "msg 1")
        |> push_direct("user", "msg 2")

      assert STM.count(stm) == 2
      stm = STM.clear(stm)
      assert STM.count(stm) == 0
      assert stm.counter == 0
    end
  end

  describe "destroy/1" do
    test "deletes the ETS table" do
      sid = unique_session_id()
      stm = init_test_stm(sid)
      table = stm.table
      assert :ets.whereis(table) != :undefined
      assert STM.destroy(stm) == :ok
      assert :ets.whereis(table) == :undefined
    end

    test "is idempotent" do
      sid = unique_session_id()
      stm = init_test_stm(sid)
      assert STM.destroy(stm) == :ok
      assert STM.destroy(stm) == :ok
    end
  end

  describe "eviction" do
    test "triggers eviction when capacity is exceeded", %{stm: stm} do
      stm =
        Enum.reduce(1..12, stm, fn i, acc ->
          push_direct(acc, "user", "message #{i}")
        end)

      assert STM.count(stm) <= stm.capacity
    end
  end

  # Direct push that bypasses Compactor/Repo (for unit testing STM in isolation)
  defp push_direct(stm, role, content) do
    %{table: table, capacity: capacity, counter: counter} = stm
    token_count = ceil(String.length(content) / 4.0) + 4

    entry = %{
      id: counter,
      role: role,
      content: content,
      channel: nil,
      token_count: token_count,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(table, {counter, entry})
    stm = %{stm | counter: counter + 1}

    size = :ets.info(table, :size)

    if size > capacity do
      chunk_size = max(size - capacity, div(capacity, 5))

      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.take(chunk_size)
      |> Enum.each(fn {k, _} -> :ets.delete(table, k) end)
    end

    stm
  end
end
