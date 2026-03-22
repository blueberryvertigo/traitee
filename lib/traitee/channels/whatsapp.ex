defmodule Traitee.Channels.WhatsApp do
  @moduledoc """
  WhatsApp channel integration via the WhatsApp Cloud API.

  Receives inbound messages via webhook (POST /api/webhook/whatsapp)
  and sends responses via the Cloud API.
  """
  use GenServer

  alias Traitee.Channels.Channel
  alias Traitee.Router, as: MessageRouter

  require Logger

  defstruct [:token, :phone_number_id, :verify_token]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def channel_type, do: :whatsapp

  def send_message(pid \\ __MODULE__, message) do
    GenServer.call(pid, {:send, message})
  end

  @doc """
  Handles incoming webhook from WhatsApp Cloud API.
  Called by the webhook controller.
  """
  def handle_webhook(params) do
    GenServer.cast(__MODULE__, {:webhook, params})
  end

  @impl true
  def init(_opts) do
    config = Traitee.Config.get([:channels, :whatsapp]) || %{}

    if config[:token] do
      Logger.info("WhatsApp channel initialized")
    else
      Logger.info("WhatsApp channel not configured, skipping")
    end

    state = %__MODULE__{
      token: config[:token],
      phone_number_id: config[:phone_number_id],
      verify_token: config[:verify_token]
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send, %{target: phone, text: text}}, _from, state) do
    result = send_whatsapp_message(state, phone, text)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:webhook, params}, state) do
    process_webhook(params, state)
    {:noreply, state}
  end

  # -- Private --

  defp process_webhook(%{"entry" => entries}, _state) do
    Enum.each(entries, fn entry ->
      changes = entry["changes"] || []

      Enum.each(changes, fn change ->
        value = change["value"] || %{}
        messages = value["messages"] || []

        Enum.each(messages, fn msg ->
          if msg["type"] == "text" do
            text = get_in(msg, ["text", "body"])
            from = msg["from"]

            if text && from do
              contact =
                (value["contacts"] || [])
                |> Enum.find(fn c -> c["wa_id"] == from end)

              sender_name =
                if contact, do: get_in(contact, ["profile", "name"]), else: nil

              inbound =
                Channel.build_inbound(
                  text,
                  from,
                  :whatsapp,
                  sender_name: sender_name,
                  channel_id: from,
                  reply_to: from,
                  metadata: %{message_id: msg["id"], timestamp: msg["timestamp"]}
                )

              Task.start(fn -> MessageRouter.route(inbound) end)
            end
          end
        end)
      end)
    end)
  end

  defp process_webhook(_params, _state), do: :ok

  defp send_whatsapp_message(%{token: token, phone_number_id: phone_id}, to, text) do
    url = "https://graph.facebook.com/v21.0/#{phone_id}/messages"

    body = %{
      messaging_product: "whatsapp",
      to: to,
      type: "text",
      text: %{body: text}
    }

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           retry: false
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
