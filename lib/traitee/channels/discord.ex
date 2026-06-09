defmodule Traitee.Channels.Discord do
  @moduledoc """
  Discord channel integration via the Nostrum library.

  Listens for messages in configured guilds/DMs and routes them
  through the session system. Sends responses back to the
  originating channel.
  """
  use GenServer

  alias Traitee.Channels.Channel
  alias Traitee.Channels.Splitter
  alias Traitee.Router, as: MessageRouter

  require Logger

  @message_limit 2000

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
      guild_ids: Enum.map(config[:guild_ids] || [], &to_string/1),
      allow_dms: Map.get(config, :allow_dms, true)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send, %{target: channel_id, text: text}}, _from, state) do
    {:reply, send_text(channel_id, text), state}
  end

  @impl true
  def handle_info({:nostrum_message, message}, state) do
    if allowed_message?(message, state) do
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

  defp allowed_message?(message, state) do
    cond do
      message.author.bot -> false
      is_nil(message.guild_id) -> state.allow_dms
      state.guild_ids == [] -> true
      true -> to_string(message.guild_id) in state.guild_ids
    end
  end

  defp send_text(channel_id, text) do
    text
    |> Splitter.split_message(@message_limit)
    |> Enum.reduce_while(:ok, fn part, :ok ->
      case create_message(channel_id, part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_message(channel_id, content) do
    case Nostrum.Api.Message.create(to_channel_id(channel_id), content: content) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.warning("Discord send failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Discord send failed: #{inspect(e)}")
      {:error, e}
  end

  defp to_channel_id(id) when is_integer(id), do: id
  defp to_channel_id(id) when is_binary(id), do: String.to_integer(id)

  defp start_consumer do
    Task.start(fn ->
      case Application.ensure_all_started(:nostrum) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to start Nostrum: #{inspect(reason)}")
      end
    end)
  end
end
