defmodule Traitee.Channels.Telegram do
  @moduledoc """
  Telegram channel integration via the ExGram library.

  Listens for messages from the Telegram Bot API and routes them
  through the session system.
  """
  use GenServer

  alias Traitee.Channels.Channel
  alias Traitee.Channels.Splitter
  alias Traitee.Router, as: MessageRouter

  require Logger

  @message_limit 4096

  defstruct [:token, :bot_info, :allow_from, error_count: 0, offset: 0]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def channel_type, do: :telegram

  def send_message(pid \\ __MODULE__, message) do
    GenServer.call(pid, {:send, message})
  end

  @impl true
  def init(_opts) do
    config = Traitee.Config.get([:channels, :telegram]) || %{}
    token = config[:token]

    skip_polling = Application.get_env(:traitee, :skip_channel_polling, false)

    cond do
      is_nil(token) ->
        Logger.info("Telegram channel not configured, skipping")

      skip_polling ->
        Logger.info("Telegram channel ready (send-only, polling disabled)")

      true ->
        Logger.info("Telegram channel starting...")
        clear_stale_connections(token)
        schedule_poll(0)
    end

    state = %__MODULE__{
      token: token,
      allow_from: config[:allow_from] || []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send, %{target: chat_id, text: text}}, _from, state) do
    result = send_telegram_message(state.token, chat_id, text)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, %{token: nil} = state), do: {:noreply, state}

  @impl true
  def handle_info(:poll, state) do
    me = self()
    token = state.token
    offset = state.offset

    Task.start_link(fn ->
      result = poll_updates(token, offset)
      send(me, {:poll_result, result})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:poll_result, {:ok, updates, new_offset}}, state) do
    process_updates(updates, state)
    schedule_poll(1_000)
    {:noreply, %{state | error_count: 0, offset: new_offset}}
  end

  @impl true
  def handle_info({:set_offset, offset}, state) do
    {:noreply, %{state | offset: offset}}
  end

  @impl true
  def handle_info({:poll_result, {:error, %{"error_code" => 401}}}, state) do
    Logger.error(
      "Telegram token is invalid (401 Unauthorized). Stopping polling. Re-run `mix traitee.onboard` to fix."
    )

    {:noreply, %{state | token: nil}}
  end

  @impl true
  def handle_info({:poll_result, {:error, reason}}, state) do
    count = state.error_count + 1
    delay = min(1_000 * Integer.pow(2, count), 60_000)

    Logger.warning(
      "Telegram poll error (attempt #{count}, retry in #{delay}ms): #{inspect(reason)}"
    )

    schedule_poll(delay)
    {:noreply, %{state | error_count: count}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  # Updates within one chat are processed sequentially (in a single Task) to
  # preserve per-chat ordering; different chats still run in parallel.
  defp process_updates(updates, state) do
    updates
    |> Enum.group_by(&update_chat_id/1)
    |> Enum.each(fn {_chat_id, chat_updates} ->
      Task.start(fn ->
        Enum.each(chat_updates, fn update -> handle_update(update, state) end)
      end)
    end)
  end

  defp update_chat_id(%{"message" => %{"chat" => %{"id" => id}}}), do: id
  defp update_chat_id(_update), do: nil

  defp handle_update(%{"message" => msg}, _state) when is_map(msg) do
    text = msg["text"]
    from = msg["from"]
    chat = msg["chat"]

    if text && from do
      inbound =
        Channel.build_inbound(
          text,
          to_string(from["id"]),
          :telegram,
          sender_name: from["first_name"],
          channel_id: to_string(chat["id"]),
          reply_to: chat["id"],
          metadata: %{message_id: msg["message_id"], chat_type: chat["type"]}
        )

      MessageRouter.route(inbound)
    end
  end

  defp handle_update(_update, _state), do: :ok

  defp poll_updates(token, offset) do
    url = "https://api.telegram.org/bot#{token}/getUpdates"

    case Req.get(url,
           params: [offset: offset, timeout: 30, limit: 100],
           receive_timeout: 35_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => results}}} ->
        new_offset =
          case results do
            [] -> offset
            _ -> results |> Enum.map(& &1["update_id"]) |> Enum.max() |> Kernel.+(1)
          end

        {:ok, results, new_offset}

      {:ok, %{body: body}} ->
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_telegram_message(token, chat_id, text) do
    text
    |> Splitter.split_message(@message_limit)
    |> Enum.reduce_while(:ok, fn part, :ok ->
      case send_telegram_part(token, chat_id, part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp send_telegram_part(token, chat_id, text) do
    case do_send(token, chat_id, text, "Markdown") do
      :ok ->
        :ok

      {:error, %{"description" => description} = body} ->
        if is_binary(description) and String.contains?(description, "can't parse entities") do
          Logger.debug("Telegram markdown parse failed, retrying without parse_mode")
          do_send(token, chat_id, text, nil)
        else
          Logger.warning("Telegram send failed: #{inspect(body)}")
          {:error, body}
        end

      {:error, reason} ->
        Logger.warning("Telegram send failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_send(token, chat_id, text, parse_mode) do
    url = "https://api.telegram.org/bot#{token}/sendMessage"
    payload = %{chat_id: chat_id, text: text}
    payload = if parse_mode, do: Map.put(payload, :parse_mode, parse_mode), else: payload

    case Req.post(url, json: payload, retry: false) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_stale_connections(token) do
    me = self()

    Task.start(fn ->
      try do
        url = "https://api.telegram.org/bot#{token}/deleteWebhook"
        Req.post(url, json: %{drop_pending_updates: false}, retry: false, receive_timeout: 5_000)

        flush_url = "https://api.telegram.org/bot#{token}/getUpdates"

        case Req.get(flush_url,
               params: [offset: -1, timeout: 0],
               retry: false,
               receive_timeout: 5_000
             ) do
          {:ok, %{status: 200, body: %{"ok" => true, "result" => [update | _]}}} ->
            send(me, {:set_offset, update["update_id"] + 1})

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end)
  end

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end
end
