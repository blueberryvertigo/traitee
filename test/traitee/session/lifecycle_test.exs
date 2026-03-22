defmodule Traitee.Session.LifecycleTest do
  use ExUnit.Case, async: true

  alias Traitee.Session.Lifecycle

  describe "new/2" do
    test "creates a session in :initializing state" do
      lc = Lifecycle.new("sess_1", :discord)
      assert lc.session_id == "sess_1"
      assert lc.channel == :discord
      assert lc.status == :initializing
      assert lc.message_count == 0
      assert lc.total_tokens == 0
      assert lc.thinking_level == :off
      assert lc.verbose_level == :off
      assert lc.group_activation == :mention
      assert %DateTime{} = lc.created_at
      assert %DateTime{} = lc.last_activity
    end
  end

  describe "transition/2 - valid transitions" do
    test "initializing -> active on :message_received" do
      lc = Lifecycle.new("s", :cli)
      assert {:ok, updated} = Lifecycle.transition(lc, :message_received)
      assert updated.status == :active
      assert updated.message_count == 1
    end

    test "active -> active on :message_received (increments count)" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      assert lc.status == :active
      assert lc.message_count == 2
    end

    test "active -> active on :response_sent (touches activity)" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      {:ok, lc} = Lifecycle.transition(lc, :response_sent)
      assert lc.status == :active
    end

    test "active -> idle on :idle_timeout" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      {:ok, lc} = Lifecycle.transition(lc, :idle_timeout)
      assert lc.status == :idle
    end

    test "idle -> active on :message_received" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      {:ok, lc} = Lifecycle.transition(lc, :idle_timeout)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      assert lc.status == :active
      assert lc.message_count == 2
    end

    test "idle -> expired on :expire" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      {:ok, lc} = Lifecycle.transition(lc, :idle_timeout)
      {:ok, lc} = Lifecycle.transition(lc, :expire)
      assert lc.status == :expired
    end

    test ":terminate works from any state" do
      for initial_event <- [:message_received] do
        lc = Lifecycle.new("s", :cli)
        {:ok, lc} = Lifecycle.transition(lc, initial_event)
        {:ok, lc} = Lifecycle.transition(lc, :terminate)
        assert lc.status == :terminated
      end
    end

    test ":reset returns to :initializing with zeroed counters" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      {:ok, lc} = Lifecycle.transition(lc, :message_received)
      assert lc.message_count == 2

      {:ok, lc} = Lifecycle.transition(lc, :reset)
      assert lc.status == :initializing
      assert lc.message_count == 0
      assert lc.total_tokens == 0
    end
  end

  describe "transition/2 - invalid transitions" do
    test "cannot transition from :terminated (except :terminate itself)" do
      lc = Lifecycle.new("s", :cli)
      {:ok, lc} = Lifecycle.transition(lc, :terminate)
      assert {:error, msg} = Lifecycle.transition(lc, :message_received)
      assert msg =~ "terminated"
    end

    test "invalid event from :initializing" do
      lc = Lifecycle.new("s", :cli)
      assert {:error, _} = Lifecycle.transition(lc, :response_sent)
      assert {:error, _} = Lifecycle.transition(lc, :idle_timeout)
      assert {:error, _} = Lifecycle.transition(lc, :expire)
    end
  end

  describe "setters" do
    test "set_thinking_level/2" do
      lc = Lifecycle.new("s", :cli)

      for level <- [:off, :minimal, :low, :medium, :high] do
        updated = Lifecycle.set_thinking_level(lc, level)
        assert updated.thinking_level == level
      end
    end

    test "set_model/2" do
      lc = Lifecycle.new("s", :cli)
      updated = Lifecycle.set_model(lc, "openai/gpt-4o")
      assert updated.model_override == "openai/gpt-4o"
    end

    test "set_model/2 with nil clears override" do
      lc = Lifecycle.new("s", :cli)
      lc = Lifecycle.set_model(lc, "openai/gpt-4o")
      updated = Lifecycle.set_model(lc, nil)
      assert updated.model_override == nil
    end

    test "set_verbose/2" do
      lc = Lifecycle.new("s", :cli)
      assert Lifecycle.set_verbose(lc, :on).verbose_level == :on
      assert Lifecycle.set_verbose(lc, :off).verbose_level == :off
    end

    test "set_group_activation/2" do
      lc = Lifecycle.new("s", :cli)
      assert Lifecycle.set_group_activation(lc, :always).group_activation == :always
      assert Lifecycle.set_group_activation(lc, :mention).group_activation == :mention
    end
  end

  describe "idle?/1" do
    test "returns false for nil last_activity" do
      lc = %Lifecycle{session_id: "s", channel: :cli, last_activity: nil}
      refute Lifecycle.idle?(lc)
    end

    test "returns false for recent activity" do
      lc = Lifecycle.new("s", :cli)
      refute Lifecycle.idle?(lc)
    end

    test "returns true for old activity" do
      old = DateTime.add(DateTime.utc_now(), -31 * 60, :second)
      lc = %Lifecycle{session_id: "s", channel: :cli, last_activity: old}
      assert Lifecycle.idle?(lc)
    end
  end

  describe "expired?/1" do
    test "returns true for :expired status" do
      lc = %Lifecycle{session_id: "s", channel: :cli, status: :expired}
      assert Lifecycle.expired?(lc)
    end

    test "returns false for nil last_activity" do
      lc = %Lifecycle{session_id: "s", channel: :cli, last_activity: nil}
      refute Lifecycle.expired?(lc)
    end

    test "returns true for very old activity" do
      old = DateTime.add(DateTime.utc_now(), -25 * 60 * 60, :second)
      lc = %Lifecycle{session_id: "s", channel: :cli, last_activity: old}
      assert Lifecycle.expired?(lc)
    end

    test "returns false for recent activity" do
      lc = Lifecycle.new("s", :cli)
      refute Lifecycle.expired?(lc)
    end
  end
end
