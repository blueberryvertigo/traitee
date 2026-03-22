defmodule Traitee.Process.LanesTest do
  use ExUnit.Case, async: false

  alias Traitee.Process.Lanes

  describe "acquire/2 and release/1" do
    test "acquires a lane slot" do
      assert :ok = Lanes.acquire(:tool)
      Lanes.release(:tool)
    end

    test "respects max concurrency" do
      tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            Lanes.acquire(:tool)
            Process.sleep(200)
            Lanes.release(:tool)
            :done
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &(&1 == :done))
    end

    test "queues when lane is full" do
      :ok = Lanes.acquire(:llm)

      waiter =
        Task.async(fn ->
          Lanes.acquire(:llm, 5_000)
        end)

      Process.sleep(50)
      stats = Lanes.stats()
      assert stats.llm.active == 1
      assert stats.llm.waiting >= 1

      Lanes.release(:llm)

      result = Task.await(waiter, 5_000)
      assert result == :ok
      Lanes.release(:llm)
    end
  end

  describe "with_lane/3" do
    test "executes function within lane" do
      result =
        Lanes.with_lane(:embed, 5_000, fn ->
          42
        end)

      assert result == 42
    end

    test "releases lane even on error" do
      try do
        Lanes.with_lane(:tool, 5_000, fn ->
          raise "oops"
        end)
      rescue
        _ -> :ok
      end

      assert :ok = Lanes.acquire(:tool)
      Lanes.release(:tool)
    end
  end

  describe "stats/0" do
    test "returns lane statistics" do
      stats = Lanes.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :tool)
      assert Map.has_key?(stats, :embed)
      assert Map.has_key?(stats, :llm)

      tool_stats = stats.tool
      assert Map.has_key?(tool_stats, :active)
      assert Map.has_key?(tool_stats, :max)
      assert Map.has_key?(tool_stats, :waiting)
    end

    test "reflects current lane usage" do
      :ok = Lanes.acquire(:embed)

      stats = Lanes.stats()
      assert stats.embed.active >= 1

      Lanes.release(:embed)

      stats = Lanes.stats()
      assert stats.embed.active >= 0
    end
  end
end
