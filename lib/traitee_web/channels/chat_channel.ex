defmodule TraiteeWeb.ChatChannel do
  @moduledoc "Phoenix channel for webchat — bridges WebSocket messages to the router."

  use Phoenix.Channel

  alias Traitee.Channels.Channel
  alias Traitee.Router, as: MessageRouter

  @impl true
  def join("chat:lobby", _payload, socket) do
    sender_id = "webchat_#{:erlang.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Traitee.PubSub, "webchat:#{sender_id}")
    socket = assign(socket, :sender_id, sender_id)
    {:ok, %{sender_id: sender_id}, socket}
  end

  @impl true
  def handle_in("message", %{"text" => text}, socket) do
    sender_id = socket.assigns.sender_id

    inbound =
      Channel.build_inbound(
        text,
        sender_id,
        :webchat,
        channel_id: sender_id,
        reply_to: sender_id,
        metadata: %{}
      )

    MessageRouter.route(inbound)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:response, text}, socket) do
    push(socket, "response", %{text: text})
    {:noreply, socket}
  end
end
