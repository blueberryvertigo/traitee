defmodule Traitee.Memory.CompactorTest do
  use ExUnit.Case, async: false

  alias Traitee.Memory.Compactor

  describe "compact/2" do
    test "accepts messages without crashing" do
      messages = [
        %{role: "user", content: "hello", token_count: 5},
        %{role: "assistant", content: "hi there", token_count: 8}
      ]

      assert Compactor.compact("compactor_test_session", messages) == :ok
    end

    test "accumulates messages below chunk threshold" do
      messages = for i <- 1..3, do: %{role: "user", content: "msg #{i}", token_count: 5}
      assert Compactor.compact("compactor_accum_test", messages) == :ok
    end
  end

  describe "flush/1" do
    test "flushes pending messages without crashing" do
      messages =
        for i <- 1..5, do: %{role: "user", content: "flush msg #{i}", token_count: 10}

      Compactor.compact("compactor_flush_test", messages)
      assert Compactor.flush("compactor_flush_test") == :ok
    end

    test "no-op for session with no pending messages" do
      assert Compactor.flush("compactor_empty_session") == :ok
    end
  end
end
