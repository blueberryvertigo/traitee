defmodule Traitee.Channels.Discord do
  @moduledoc """
  Discord channel integration via the Nostrum library.

  Listens for messages in configured guilds/DMs and routes them
  through the session system. Sends responses back to the
  originating channel.
  """
  use GenServer

  alias Traitee.Channels.Channel
  alias Traitee.Router, as: MessageRouter

  require Logger

  defstruct [:token, :guild_ids, :allow_dms]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def channel_type, do: :discord

  def send_message(pid \\ __MODULE__, message) do
    GenServer.call(pid, {:send, message})
  end

  @impl true
  def init(_opts) do
    config = Traitee.Config.get([:channels, :discord]) || %{}
    token = config[:token]
    skip_polling = Application.get_env(:traitee, :skip_channel_polling, false)

    cond do
      is_nil(token) ->
        Logger.info("Discord channel not configured, skipping")

      skip_polling ->
        Application.put_env(:nostrum, :token, token)
        Logger.info("Discord channel ready (send-only, gateway disabled)")

      true ->
        Application.put_env(:nostrum, :token, token)

        Application.put_env(:nostrum, :gateway_intents, [
          :guilds,
          :guild_messages,
          :message_content,
          :direct_messages
        ])

        Logger.info("Discord channel starting...")
        start_consumer()
    end

    state = %__MODULE__{
      token: token,
      guild_ids: config[:guild_ids] || [],
      allow_dms: config[:allow_dms] || true
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send, %{target: channel_id, text: text}}, _from, state) do
    result =
      try do
        Nostrum.Api.Message.create(String.to_integer(channel_id), content: text)
        :ok
      rescue
        e -> {:error, e}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:nostrum_message, message}, state) do
    unless message.author.bot do
      inbound =
        Channel.build_inbound(
          message.content,
          to_string(message.author.id),
          :discord,
          sender_name: message.author.username,
          channel_id: to_string(message.channel_id),
          reply_to: message.channel_id,
          metadata: %{guild_id: message.guild_id, message_id: message.id}
        )

      Task.start(fn -> MessageRouter.route(inbound) end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp start_consumer do
    Task.start(fn ->
      try do
        Application.ensure_all_started(:nostrum)
      rescue
        e -> Logger.warning("Failed to start Nostrum: #{inspect(e)}")
      end
    end)
  end
end
