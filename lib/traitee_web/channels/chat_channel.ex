defmodule TraiteeWeb.ChatChannel do
  @moduledoc "Phoenix channel for webchat — bridges WebSocket messages to the router."

  use Phoenix.Channel

  alias Traitee.Channels.Channel
  alias Traitee.Router, as: MessageRouter

  @impl true
  def join("chat:lobby", payload, socket) do
    sender_id = resolve_sender_id(payload, socket)
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

  @impl true
  def handle_info(:typing, socket) do
    push(socket, "typing", %{})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_chunk, text}, socket) do
    push(socket, "stream_chunk", %{text: text})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_done, text}, socket) do
    push(socket, "stream_done", %{text: text})
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Prefer a client-provided id (join payload, then connect params) so a
  # rejoin keeps the same PubSub topic and in-flight replies are not lost.
  defp resolve_sender_id(payload, socket) do
    client_id = payload["sender_id"] || socket.assigns[:client_sender_id]

    case sanitize_id(client_id) do
      nil -> "webchat_#{:erlang.unique_integer([:positive])}"
      id -> "webchat_#{id}"
    end
  end

  defp sanitize_id(id) when is_binary(id) do
    case id |> String.replace(~r/[^A-Za-z0-9_-]/, "") |> String.slice(0, 64) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp sanitize_id(_id), do: nil
end
