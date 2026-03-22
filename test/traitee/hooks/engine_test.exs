defmodule Traitee.Hooks.EngineTest do
  use ExUnit.Case, async: false

  alias Traitee.Hooks.Engine

  setup do
    for hook_point <- [
          :before_message,
          :after_message,
          :before_tool,
          :after_tool,
          :on_error,
          :on_session_start,
          :on_session_end,
          :on_compaction,
          :on_config_change
        ] do
      for {name, _} <- Engine.list(hook_point) do
        Engine.unregister(hook_point, name)
      end
    end

    :ok
  end

  describe "register/3 and list/1" do
    test "registers a hook handler" do
      handler = fn ctx -> {:ok, ctx} end
      :ok = Engine.register(:before_message, :test_hook, handler)

      hooks = Engine.list(:before_message)
      assert length(hooks) == 1
      assert {name, _} = hd(hooks)
      assert name == :test_hook
    end

    test "registers multiple hooks for same point" do
      :ok = Engine.register(:after_message, :hook_a, fn ctx -> {:ok, ctx} end)
      :ok = Engine.register(:after_message, :hook_b, fn ctx -> {:ok, ctx} end)

      hooks = Engine.list(:after_message)
      assert length(hooks) == 2
    end

    test "returns empty list for unregistered hook point" do
      hooks = Engine.list(:on_session_start)
      assert hooks == []
    end
  end

  describe "unregister/2" do
    test "removes a hook by name" do
      :ok = Engine.register(:before_tool, :temp_hook, fn ctx -> {:ok, ctx} end)
      assert length(Engine.list(:before_tool)) == 1

      :ok = Engine.unregister(:before_tool, :temp_hook)
      assert Engine.list(:before_tool) == []
    end
  end

  describe "fire/2" do
    test "runs hooks in order and passes context through" do
      :ok =
        Engine.register(:before_message, :step1, fn ctx ->
          {:ok, Map.put(ctx, :step1, true)}
        end)

      :ok =
        Engine.register(:before_message, :step2, fn ctx ->
          {:ok, Map.put(ctx, :step2, true)}
        end)

      {:ok, result} = Engine.fire(:before_message, %{input: "hello"})
      assert result.step1 == true
      assert result.step2 == true
      assert result.input == "hello"
    end

    test "halts the chain when a hook returns :halt" do
      :ok =
        Engine.register(:after_tool, :halter, fn _ctx ->
          {:halt, "blocked"}
        end)

      :ok =
        Engine.register(:after_tool, :never_reached, fn ctx ->
          {:ok, Map.put(ctx, :reached, true)}
        end)

      assert {:halt, "blocked"} = Engine.fire(:after_tool, %{})
    end

    test "handles hook crashes gracefully" do
      :ok =
        Engine.register(:on_error, :crasher, fn _ctx ->
          raise "boom"
        end)

      :ok =
        Engine.register(:on_error, :survivor, fn ctx ->
          {:ok, Map.put(ctx, :survived, true)}
        end)

      {:ok, result} = Engine.fire(:on_error, %{})
      assert result.survived == true
    end

    test "logs warning for unexpected return values" do
      :ok =
        Engine.register(:on_compaction, :bad_return, fn _ctx ->
          :unexpected
        end)

      :ok =
        Engine.register(:on_compaction, :good_return, fn ctx ->
          {:ok, Map.put(ctx, :good, true)}
        end)

      {:ok, result} = Engine.fire(:on_compaction, %{})
      assert result.good == true
    end

    test "returns context unchanged for no hooks" do
      {:ok, result} = Engine.fire(:on_config_change, %{test: true})
      assert result == %{test: true}
    end
  end

  describe "fire_async/2" do
    test "does not block or crash" do
      :ok =
        Engine.register(:on_session_end, :async_hook, fn ctx ->
          {:ok, ctx}
        end)

      assert :ok = Engine.fire_async(:on_session_end, %{session_id: "test"})
      Process.sleep(50)
    end
  end
end
