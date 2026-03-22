defmodule Traitee.Channels.ChannelTest do
  use ExUnit.Case, async: true

  alias Traitee.Channels.Channel

  describe "build_inbound/4" do
    test "builds a normalized inbound message" do
      result = Channel.build_inbound("Hello!", "user_1", :discord)

      assert result.text == "Hello!"
      assert result.sender_id == "user_1"
      assert result.channel_type == :discord
      assert result.sender_name == nil
      assert result.channel_id == nil
      assert result.reply_to == nil
      assert result.metadata == %{}
    end

    test "includes optional fields" do
      result =
        Channel.build_inbound("Hi", "u1", :telegram,
          sender_name: "John",
          channel_id: "chan_123",
          reply_to: "msg_456",
          metadata: %{group: true}
        )

      assert result.sender_name == "John"
      assert result.channel_id == "chan_123"
      assert result.reply_to == "msg_456"
      assert result.metadata == %{group: true}
    end

    test "works with all channel types" do
      for ch <- [:discord, :telegram, :whatsapp, :signal, :webchat, :cli] do
        result = Channel.build_inbound("test", "sender", ch)
        assert result.channel_type == ch
      end
    end
  end
end
