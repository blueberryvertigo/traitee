defmodule Traitee.Tools.ChannelSend do
  @moduledoc "Tool for sending messages to a specific channel (Telegram, Discord, etc.)."

  @behaviour Traitee.Tools.Tool

  require Logger

  @impl true
  def name, do: "channel_send"

  @impl true
  def description do
    "Send a message to the user on a specific channel (telegram, discord, whatsapp, signal). " <>
      "Use this when the user asks you to message them on another platform."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "channel" => %{
          "type" => "string",
          "enum" => ["telegram", "discord", "whatsapp", "signal"],
          "description" => "The channel to send the message on"
        },
        "message" => %{
          "type" => "string",
          "description" => "The message text to send"
        },
        "target" => %{
          "type" => "string",
          "description" =>
            "Optional explicit target (chat ID / user ID). If omitted, uses the stored delivery info from the session."
        }
      },
      "required" => ["channel", "message"]
    }
  end

  @impl true
  def execute(%{"channel" => channel_str, "message" => message} = args) do
    channel = String.to_existing_atom(channel_str)
    session_channels = args["_session_channels"] || %{}
    explicit_target = args["target"]

    target = resolve_target(channel, explicit_target, session_channels)

    case target do
      nil ->
        available = session_channels |> Map.keys() |> Enum.map_join(", ", &to_string/1)

        {:error,
         "No delivery target known for #{channel_str}. " <>
           "The user needs to message me on #{channel_str} first, or provide a target ID. " <>
           if(available != "",
             do: "Known channels: #{available}",
             else: "No channels connected yet."
           )}

      target_id ->
        outbound = %{
          text: message,
          channel_type: channel,
          target: to_string(target_id),
          reply_to: nil,
          metadata: %{}
        }

        case dispatch(channel, outbound) do
          :ok ->
            {:ok, "Message sent to #{channel_str}."}

          {:error, reason} ->
            {:error, "Failed to send to #{channel_str}: #{inspect(reason)}"}
        end
    end
  rescue
    ArgumentError ->
      {:error, "Unknown channel: #{channel_str}. Supported: telegram, discord, whatsapp, signal"}
  end

  def execute(_), do: {:error, "Missing required parameters: channel, message"}

  defp resolve_target(_channel, explicit, _session_channels)
       when is_binary(explicit) and explicit != "" do
    explicit
  end

  defp resolve_target(channel, _explicit, session_channels) do
    case Map.get(session_channels, channel) do
      %{reply_to: reply_to} when not is_nil(reply_to) -> reply_to
      %{sender_id: sender_id} when not is_nil(sender_id) -> sender_id
      _ -> fallback_target(channel)
    end
  end

  defp fallback_target(channel) do
    case Traitee.Config.owner_id_for_channel(channel) do
      nil -> nil
      "" -> nil
      id -> id
    end
  end

  defp dispatch(:telegram, outbound), do: Traitee.Channels.Telegram.send_message(outbound)
  defp dispatch(:discord, outbound), do: Traitee.Channels.Discord.send_message(outbound)
  defp dispatch(:whatsapp, outbound), do: Traitee.Channels.WhatsApp.send_message(outbound)
  defp dispatch(:signal, outbound), do: Traitee.Channels.Signal.send_message(outbound)
  defp dispatch(channel, _), do: {:error, "No handler for channel: #{channel}"}
end
