defmodule Traitee.Router do
  @moduledoc """
  Inbound message router with multi-agent routing, security checks,
  and typing indicators. Receives normalized messages from all channels
  and dispatches them to the appropriate session GenServer.
  """

  alias Traitee.Session
  alias Traitee.Session.Server, as: SessionServer
  alias Traitee.Routing.AgentRouter
  alias Traitee.AutoReply.CommandRegistry
  alias Traitee.Security.Allowlist
  alias Traitee.Security.Pairing

  require Logger

  def route(inbound) do
    %{text: text, sender_id: sender_id, channel_type: channel_type} = inbound

    with :ok <- check_security(inbound),
         :pass <- check_auto_reply(inbound) do
      if is_chat_command?(text) do
        handle_command(text, inbound)
      else
        route_to_agent(inbound)
      end
    else
      {:blocked, reason} ->
        Logger.info("Blocked #{sender_id}@#{channel_type}: #{reason}")

      {:pairing, code} ->
        deliver_response(
          inbound,
          "You're not yet approved. Your pairing code is: #{code}\nAsk the owner to run: /pairing approve #{code}"
        )

      {:auto_reply, response} ->
        deliver_response(inbound, response)
    end
  end

  defp check_security(inbound) do
    if security_enabled?() do
      sender_id = to_string(inbound.sender_id)
      channel_type = inbound.channel_type

      cond do
        Traitee.Config.sender_is_owner?(sender_id, channel_type) ->
          :ok

        not Allowlist.allowed?(sender_id, channel_type) ->
          {:blocked, :not_allowlisted}

        true ->
          check_dm_policy(sender_id, channel_type)
      end
    else
      :ok
    end
  end

  defp check_dm_policy(sender_id, channel_type) do
    case Allowlist.dm_policy(channel_type) do
      :open ->
        :ok

      :closed ->
        {:blocked, :closed_channel}

      :pairing ->
        case Pairing.check_sender(sender_id, channel_type) do
          :approved -> :ok
          {:pending, code} -> {:pairing, code}
        end
    end
  end

  defp check_auto_reply(_inbound), do: :pass

  defp route_to_agent(inbound) do
    route = AgentRouter.resolve(inbound)
    session_id = route.session_key

    case Session.ensure_started(session_id, inbound.channel_type) do
      {:ok, pid} ->
        start_typing(inbound)

        Task.start(fn ->
          try do
            reply_to = inbound[:reply_to] || inbound.sender_id
            channel_opts = [reply_to: reply_to, sender_id: inbound.sender_id]

            case SessionServer.send_message(pid, inbound.text, inbound.channel_type, channel_opts) do
              {:ok, response} ->
                stop_typing(inbound)
                deliver_response(inbound, response)

              {:error, reason} ->
                stop_typing(inbound)
                Logger.warning("Session error for #{session_id}: #{inspect(reason)}")
                deliver_response(inbound, "[error] Failed to process message: #{inspect(reason)}")
            end
          after
            stop_typing(inbound)
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to start session #{session_id}: #{inspect(reason)}")
    end
  end

  # -- Typing indicators --

  defp start_typing(inbound) do
    target = inbound[:reply_to] || inbound[:channel_id] || inbound.sender_id

    try do
      ref = Traitee.Channels.Typing.start(inbound.channel_type, to_string(target))
      Process.put({__MODULE__, :typing_ref}, ref)
    rescue
      _ -> :ok
    end
  end

  defp stop_typing(_inbound) do
    case Process.get({__MODULE__, :typing_ref}) do
      nil ->
        :ok

      ref ->
        Traitee.Channels.Typing.stop(ref)
        Process.delete({__MODULE__, :typing_ref})
    end
  end

  # -- Security --

  defp security_enabled? do
    Traitee.Config.get([:security, :enabled]) == true
  end

  # -- Commands --

  defp is_chat_command?(text) do
    String.starts_with?(text, "/")
  end

  defp handle_command(text, inbound) do
    context = %{inbound: inbound}

    case CommandRegistry.execute(text, context) do
      {:ok, response} ->
        deliver_response(inbound, response)

      {:error, :unknown_command} ->
        deliver_response(inbound, "Unknown command: #{text}. Type /help for commands.")

      {:error, :unauthorized} ->
        deliver_response(inbound, "You don't have permission for that command.")

      {:error, reason} ->
        deliver_response(inbound, "Error: #{inspect(reason)}")
    end
  end

  # -- Delivery --

  defp deliver_response(inbound, text) do
    channel_type = inbound.channel_type
    target = inbound[:reply_to] || inbound[:channel_id] || inbound.sender_id

    outbound = %{
      text: text,
      channel_type: channel_type,
      target: to_string(target),
      reply_to: inbound[:reply_to],
      metadata: %{}
    }

    case channel_type do
      :discord -> Traitee.Channels.Discord.send_message(outbound)
      :telegram -> Traitee.Channels.Telegram.send_message(outbound)
      :whatsapp -> Traitee.Channels.WhatsApp.send_message(outbound)
      :signal -> Traitee.Channels.Signal.send_message(outbound)
      :webchat -> Phoenix.PubSub.broadcast(Traitee.PubSub, "webchat:#{target}", {:response, text})
      _ -> Logger.warning("No delivery handler for channel #{channel_type}")
    end
  end
end
