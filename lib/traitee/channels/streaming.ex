defmodule Traitee.Channels.Streaming do
  @moduledoc "Stream LLM responses to channels incrementally."

  alias Traitee.Channels.Typing

  require Logger

  @edit_interval_ms 500

  @spec stream_to_channel(atom(), String.t(), reference()) :: :ok
  def stream_to_channel(channel_type, target, stream_ref) do
    typing_ref = Typing.start(channel_type, target)
    buffer = collect_stream(stream_ref, channel_type, target, "", nil, 0)
    Typing.stop(typing_ref)

    send_final(channel_type, target, buffer)
    :ok
  end

  @spec start_typing(atom(), String.t()) :: reference()
  defdelegate start_typing(channel_type, target), to: Typing, as: :start

  @spec stop_typing(reference()) :: :ok
  defdelegate stop_typing(ref), to: Typing, as: :stop

  # -- Private --

  defp collect_stream(stream_ref, channel_type, target, buffer, msg_id, last_edit_ts) do
    receive do
      {:chunk, ^stream_ref, text} ->
        new_buffer = buffer <> text
        now = System.monotonic_time(:millisecond)

        msg_id =
          if now - last_edit_ts >= @edit_interval_ms do
            push_update(channel_type, target, new_buffer, msg_id)
          else
            msg_id
          end

        collect_stream(stream_ref, channel_type, target, new_buffer, msg_id, now)

      {:done, ^stream_ref} ->
        buffer

      {:error, ^stream_ref, reason} ->
        Logger.warning("Stream error: #{inspect(reason)}")
        buffer
    after
      120_000 ->
        Logger.warning("Stream timeout for #{channel_type}:#{target}")
        buffer
    end
  end

  defp push_update(:webchat, target, text, _msg_id) do
    Phoenix.PubSub.broadcast(Traitee.PubSub, "webchat:#{target}", {:stream_chunk, text})
    nil
  end

  defp push_update(:whatsapp, _target, _text, msg_id) do
    msg_id
  end

  defp push_update(:discord, target, text, nil) do
    case send_channel_message(:discord, target, text) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp push_update(:discord, target, text, msg_id) do
    edit_channel_message(:discord, target, msg_id, text)
    msg_id
  end

  defp push_update(:telegram, target, text, nil) do
    case send_channel_message(:telegram, target, text) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp push_update(:telegram, target, text, msg_id) do
    edit_channel_message(:telegram, target, msg_id, text)
    msg_id
  end

  defp push_update(_channel, _target, _text, msg_id), do: msg_id

  defp send_final(:webchat, target, text) do
    Phoenix.PubSub.broadcast(Traitee.PubSub, "webchat:#{target}", {:stream_done, text})
  end

  defp send_final(channel_type, target, text) do
    outbound = %{
      text: text,
      channel_type: channel_type,
      target: target,
      reply_to: nil,
      metadata: %{}
    }

    case channel_type do
      :discord -> Traitee.Channels.Discord.send_message(outbound)
      :telegram -> Traitee.Channels.Telegram.send_message(outbound)
      :whatsapp -> Traitee.Channels.WhatsApp.send_message(outbound)
      :signal -> Traitee.Channels.Signal.send_message(outbound)
      _ -> :ok
    end
  end

  defp send_channel_message(:discord, channel_id, text) do
    try do
      case Nostrum.Api.Message.create(String.to_integer(channel_id), content: text) do
        {:ok, msg} -> {:ok, msg.id}
        error -> error
      end
    rescue
      _ -> {:error, :discord_send_failed}
    end
  end

  defp send_channel_message(:telegram, chat_id, text) do
    config = Traitee.Config.get([:channels, :telegram]) || %{}
    token = config[:token]
    url = "https://api.telegram.org/bot#{token}/sendMessage"

    case Req.post(url, json: %{chat_id: chat_id, text: text}, retry: false) do
      {:ok, %{status: 200, body: %{"result" => %{"message_id" => id}}}} -> {:ok, id}
      _ -> {:error, :telegram_send_failed}
    end
  end

  defp send_channel_message(_, _, _), do: {:error, :unsupported}

  defp edit_channel_message(:discord, channel_id, msg_id, text) do
    try do
      Nostrum.Api.Message.edit(String.to_integer(channel_id), msg_id, content: text)
    rescue
      _ -> :ok
    end
  end

  defp edit_channel_message(:telegram, chat_id, msg_id, text) do
    config = Traitee.Config.get([:channels, :telegram]) || %{}
    token = config[:token]
    url = "https://api.telegram.org/bot#{token}/editMessageText"
    Req.post(url, json: %{chat_id: chat_id, message_id: msg_id, text: text}, retry: false)
    :ok
  end

  defp edit_channel_message(_, _, _, _), do: :ok
end
