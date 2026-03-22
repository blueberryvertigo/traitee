defmodule Traitee.Routing.BindingsTest do
  use ExUnit.Case, async: true

  alias Traitee.Routing.Bindings

  describe "match/2" do
    test "matches :default binding to any inbound" do
      binding = %Bindings{
        agent_id: "default",
        match_type: :default,
        match_value: nil,
        priority: 4
      }

      assert Bindings.match([binding], %{sender_id: "user1", channel_type: :discord}) == binding
    end

    test "matches :peer binding by sender_id" do
      binding = %Bindings{
        agent_id: "vip",
        match_type: :peer,
        match_value: "user42",
        priority: 0
      }

      assert Bindings.match([binding], %{sender_id: "user42"}) == binding
      assert Bindings.match([binding], %{sender_id: "user99"}) == nil
    end

    test "matches :guild binding by guild_id" do
      binding = %Bindings{
        agent_id: "work",
        match_type: :guild,
        match_value: "guild_123",
        priority: 1
      }

      assert Bindings.match([binding], %{guild_id: "guild_123"}) == binding
      assert Bindings.match([binding], %{guild_id: "guild_999"}) == nil
    end

    test "matches :guild binding by server_id fallback" do
      binding = %Bindings{
        agent_id: "work",
        match_type: :guild,
        match_value: "srv_1",
        priority: 1
      }

      assert Bindings.match([binding], %{server_id: "srv_1"}) == binding
    end

    test "matches :account binding" do
      binding = %Bindings{
        agent_id: "phone",
        match_type: :account,
        match_value: "+1234567890",
        priority: 2
      }

      assert Bindings.match([binding], %{phone_number: "+1234567890"}) == binding
    end

    test "matches :channel binding by channel_type" do
      binding = %Bindings{
        agent_id: "telegram_agent",
        match_type: :channel,
        match_value: :telegram,
        priority: 3
      }

      assert Bindings.match([binding], %{channel_type: :telegram}) == binding
      assert Bindings.match([binding], %{channel_type: :discord}) == nil
    end

    test "returns first matching binding (priority order)" do
      bindings = [
        %Bindings{agent_id: "peer", match_type: :peer, match_value: "user1", priority: 0},
        %Bindings{agent_id: "channel", match_type: :channel, match_value: :discord, priority: 3},
        %Bindings{agent_id: "default", match_type: :default, match_value: nil, priority: 4}
      ]

      inbound = %{sender_id: "user1", channel_type: :discord}
      matched = Bindings.match(bindings, inbound)
      assert matched.agent_id == "peer"
    end

    test "falls through to default when nothing matches" do
      bindings = [
        %Bindings{agent_id: "vip", match_type: :peer, match_value: "special", priority: 0},
        %Bindings{agent_id: "fallback", match_type: :default, match_value: nil, priority: 4}
      ]

      matched = Bindings.match(bindings, %{sender_id: "regular_user"})
      assert matched.agent_id == "fallback"
    end

    test "returns nil when no binding matches" do
      bindings = [
        %Bindings{agent_id: "vip", match_type: :peer, match_value: "special", priority: 0}
      ]

      assert Bindings.match(bindings, %{sender_id: "nobody"}) == nil
    end
  end
end
