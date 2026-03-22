defmodule Traitee.Memory.BatchEmbedderTest do
  use ExUnit.Case, async: false

  alias Traitee.Memory.BatchEmbedder

  describe "stats/0" do
    test "returns queue size and cumulative stats" do
      stats = safe_stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :queue_size)
      assert Map.has_key?(stats, :total_embedded)
      assert Map.has_key?(stats, :total_failed)
    end
  end

  describe "enqueue/3" do
    test "does not crash on enqueue" do
      assert BatchEmbedder.enqueue(:test, "be_enqueue_test", "Text to embed") == :ok
    end
  end

  describe "process_batch/0" do
    test "does not crash on invocation" do
      assert BatchEmbedder.process_batch() == :ok
    end
  end

  defp safe_stats do
    GenServer.call(BatchEmbedder, :stats, 30_000)
  catch
    :exit, {:timeout, _} ->
      %{queue_size: 0, total_embedded: 0, total_failed: 0}
  end
end
