defmodule Traitee.Channels.Telegram do
  @moduledoc """
  Telegram channel integration via the ExGram library.

  Listens for messages from the Telegram Bot API and routes them
  through the session system.
  """
  use GenServer

  alias Traitee.Channels.Channel
  alias Traitee.Router, as: MessageRouter

  require Logger

  defstruct [:token, :bot_info, :allow_from, error_count: 0]

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

    Task.start_link(fn ->
      result = poll_updates(token)
      send(me, {:poll_result, result})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:poll_result, {:ok, updates}}, state) do
    Enum.each(updates, fn update ->
      handle_update(update, state)
    end)

    schedule_poll(1_000)
    {:noreply, %{state | error_count: 0}}
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

      Task.start(fn -> MessageRouter.route(inbound) end)
    end
  end

  defp handle_update(_update, _state), do: :ok

  defp poll_updates(token) do
    offset = :persistent_term.get({__MODULE__, :offset}, 0)
    url = "https://api.telegram.org/bot#{token}/getUpdates"

    case Req.get(url,
           params: [offset: offset, timeout: 30, limit: 100],
           receive_timeout: 35_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => results}}} ->
        if results != [] do
          max_id = results |> Enum.map(& &1["update_id"]) |> Enum.max()
          :persistent_term.put({__MODULE__, :offset}, max_id + 1)
        end

        {:ok, results}

      {:ok, %{body: body}} ->
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_telegram_message(token, chat_id, text) do
    url = "https://api.telegram.org/bot#{token}/sendMessage"

    case Req.post(url,
           json: %{chat_id: chat_id, text: text, parse_mode: "Markdown"},
           retry: false
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_stale_connections(token) do
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
            :persistent_term.put({__MODULE__, :offset}, update["update_id"] + 1)

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
