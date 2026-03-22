defmodule Traitee.Channels.Channel do
  @moduledoc """
  Behaviour for messaging channel integrations.

  Each channel (Discord, Telegram, WhatsApp, Signal) implements these
  callbacks to normalize inbound/outbound messages.
  """

  @type inbound :: %{
          text: String.t(),
          sender_id: String.t(),
          sender_name: String.t() | nil,
          channel_type: atom(),
          channel_id: String.t() | nil,
          reply_to: term() | nil,
          metadata: map()
        }

  @type outbound :: %{
          text: String.t(),
          channel_type: atom(),
          target: String.t(),
          reply_to: term() | nil,
          metadata: map()
        }

  @callback start_link(config :: map()) :: GenServer.on_start()
  @callback send_message(pid :: pid(), message :: outbound()) :: :ok | {:error, term()}
  @callback channel_type() :: atom()

  @doc """
  Builds a normalized inbound message map.
  """
  def build_inbound(text, sender_id, channel_type, opts \\ []) do
    %{
      text: text,
      sender_id: sender_id,
      sender_name: opts[:sender_name],
      channel_type: channel_type,
      channel_id: opts[:channel_id],
      reply_to: opts[:reply_to],
      metadata: opts[:metadata] || %{}
    }
  end
end
