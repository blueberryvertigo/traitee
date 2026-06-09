defmodule Traitee.Router do
  @moduledoc """
  Inbound message router with multi-agent routing, security checks,
  and typing indicators. Receives normalized messages from all channels
  and dispatches them to the appropriate session GenServer.
  """

  alias Traitee.AutoReply.{CommandRegistry, Pipeline}
  alias Traitee.Channels.Typing
  alias Traitee.Routing.AgentRouter
  alias Traitee.Security.{Allowlist, Audit, Pairing, RateLimiter}
  alias Traitee.Session
  alias Traitee.Session.Server, as: SessionServer

  require Logger

  def route(inbound) do
    %{text: text, sender_id: sender_id, channel_type: channel_type} = inbound

    with :ok <- check_security(inbound),
         :ok <- check_rate_limit(inbound),
         :pass <- check_auto_reply(inbound) do
      if chat_command?(text) do
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

      {:rate_limited, retry_after_ms} ->
        deliver_response(
          inbound,
          "You're sending messages too quickly. Please wait #{div(retry_after_ms, 1000) + 1}s and try again."
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

  # Real per-sender rate limiting applied at the router. The previous
  # Hooks.Engine-based wiring never fired because Hooks.Engine.fire/2 was
  # not called from production code. We use the sender_id as the key so
  # an attacker cannot create fresh sessions to sidestep the limit.
  defp check_rate_limit(inbound) do
    key = {:inbound, inbound.channel_type, to_string(inbound.sender_id)}

    case RateLimiter.check(key) do
      :ok ->
        :ok

      {:error, :rate_limited, retry_after_ms} ->
        Audit.record(:rate_limited, %{
          channel: inbound.channel_type,
          sender: to_string(inbound.sender_id),
          decision: :deny,
          reason: "inbound rate limit exhausted",
          retry_after_ms: retry_after_ms
        })

        {:rate_limited, retry_after_ms}
    end
  rescue
    # Fail-open on RateLimiter errors so a misconfigured/absent ETS table
    # doesn't brick the bot, but log loudly.
    e ->
      Logger.warning("[Router] RateLimiter check failed: #{inspect(e)} — proceeding")
      :ok
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

  defp check_auto_reply(inbound) do
    case Pipeline.process(inbound, %{}) do
      {:reply, _context} -> :pass
      {:command, response} -> {:auto_reply, response}
      {:skill, _content} -> :pass
      :debounced -> {:blocked, :debounced}
      :ignored -> {:blocked, :ignored_in_group}
    end
  rescue
    _ -> :pass
  end

  defp route_to_agent(inbound) do
    route = AgentRouter.resolve(inbound)
    session_id = route.session_key

    case Session.ensure_started(session_id, inbound.channel_type) do
      {:ok, pid} ->
        # Typing starts INSIDE the response task so the same process that
        # started the loop stops it (the pid travels lexically, not via the
        # process dictionary), and the loop's parent-liveness check tracks
        # the task rather than the short-lived routing process.
        Task.start(fn ->
          typing = start_typing(inbound)

          try do
            handle_session_turn(pid, inbound, session_id)
          after
            stop_typing(typing)
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to start session #{session_id}: #{inspect(reason)}")
    end
  end

  defp handle_session_turn(pid, inbound, session_id) do
    reply_to = inbound[:reply_to] || inbound.sender_id
    channel_opts = [reply_to: reply_to, sender_id: inbound.sender_id]

    case call_session(pid, inbound, channel_opts) do
      {:ok, response} ->
        deliver_response(inbound, response)

      {:error, :session_timeout} ->
        Logger.warning("Session call timed out for #{session_id}")

        deliver_response(
          inbound,
          "This is taking longer than expected — your request timed out. Please try again."
        )

      {:error, reason} ->
        Logger.warning("Session error for #{session_id}: #{inspect(reason)}")
        deliver_response(inbound, "[error] Failed to process message: #{inspect(reason)}")
    end
  end

  # The 300s GenServer.call can exit with :timeout when the session is busy
  # with queued messages or a long turn — catch it so the user still gets a
  # response instead of a silently dead task.
  defp call_session(pid, inbound, channel_opts) do
    SessionServer.send_message(pid, inbound.text, inbound.channel_type, channel_opts)
  catch
    :exit, {:timeout, _} -> {:error, :session_timeout}
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  # -- Typing indicators --

  defp start_typing(inbound) do
    target = inbound[:reply_to] || inbound[:channel_id] || inbound.sender_id
    Typing.start(inbound.channel_type, to_string(target))
  rescue
    _ -> nil
  end

  defp stop_typing(typing_pid), do: Typing.stop(typing_pid)

  # -- Security --

  defp security_enabled? do
    Traitee.Config.get([:security, :enabled]) == true
  end

  # -- Commands --

  defp chat_command?(text) do
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

      {:error, :cli_only} ->
        deliver_response(inbound, "That command is only available on CLI.")

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
