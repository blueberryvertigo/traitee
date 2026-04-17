defmodule Traitee.Tools.ChannelSend do
  @moduledoc "Tool for sending messages to a specific channel (Telegram, Discord, etc.)."

  @behaviour Traitee.Tools.Tool

  alias Traitee.Security.ToolGate

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

    case resolve_target(channel, explicit_target, session_channels, args) do
      {:ok, target_id} ->
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

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError ->
      {:error, "Unknown channel: #{channel_str}. Supported: telegram, discord, whatsapp, signal"}
  end

  def execute(_), do: {:error, "Missing required parameters: channel, message"}

  # Target resolution policy (previously far too permissive — would send to
  # the configured owner's account on ANY configured channel even if the
  # current session had no relationship with that channel, enabling
  # cross-channel data exfiltration):
  #
  #   1. If the caller provides an explicit target, it MUST match a
  #      sender_id / reply_to already known for that channel in this
  #      session. If not, the send is refused.
  #   2. Otherwise the stored session-channel target is used.
  #   3. If no channel presence exists in this session, the send is
  #      refused. Owner-level sends to previously-unseen channels now
  #      require explicit owner-gated invocation.
  defp resolve_target(channel, explicit, session_channels, args)
       when is_binary(explicit) and explicit != "" do
    known = session_channel_identities(channel, session_channels)

    if explicit in known do
      {:ok, explicit}
    else
      # Explicit targeting to an unknown recipient — only allowed from
      # owner-authenticated sessions, since it otherwise enables
      # cross-channel exfiltration.
      case ToolGate.require_owner(args, "channel_send") do
        :ok -> {:ok, explicit}
        {:error, _} = err -> err
      end
    end
  end

  defp resolve_target(channel, _explicit, session_channels, _args) do
    case Map.get(session_channels, channel) do
      %{reply_to: reply_to} when not is_nil(reply_to) ->
        {:ok, reply_to}

      %{sender_id: sender_id} when not is_nil(sender_id) ->
        {:ok, sender_id}

      _ ->
        available =
          session_channels
          |> Map.keys()
          |> Enum.map_join(", ", &to_string/1)

        hint =
          if available == "",
            do: "No channels connected yet.",
            else: "Known channels: #{available}."

        {:error,
         "No delivery target known for #{channel}. " <>
           "The user must message me on that channel first (session presence is required). " <>
           hint}
    end
  end

  defp session_channel_identities(channel, session_channels) do
    case Map.get(session_channels, channel) do
      nil ->
        []

      info ->
        [info[:reply_to], info[:sender_id]]
        |> Enum.reject(&(is_nil(&1) or &1 == ""))
        |> Enum.map(&to_string/1)
    end
  end

  defp dispatch(:telegram, outbound), do: Traitee.Channels.Telegram.send_message(outbound)
  defp dispatch(:discord, outbound), do: Traitee.Channels.Discord.send_message(outbound)
  defp dispatch(:whatsapp, outbound), do: Traitee.Channels.WhatsApp.send_message(outbound)
  defp dispatch(:signal, outbound), do: Traitee.Channels.Signal.send_message(outbound)
  defp dispatch(channel, _), do: {:error, "No handler for channel: #{channel}"}
end
