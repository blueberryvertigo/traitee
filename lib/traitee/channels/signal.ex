defmodule Traitee.Channels.Signal do
  @moduledoc """
  Signal channel integration via signal-cli subprocess.

  Manages a signal-cli process via Elixir Port, communicating
  over stdin/stdout with JSON-RPC.
  """
  use GenServer

  alias Traitee.Channels.Channel
  alias Traitee.Router, as: MessageRouter

  require Logger

  defstruct [:port, :cli_path, :phone_number, :buffer]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def channel_type, do: :signal

  def send_message(pid \\ __MODULE__, message) do
    GenServer.call(pid, {:send, message}, 30_000)
  end

  @impl true
  def init(_opts) do
    config = Traitee.Config.get([:channels, :signal]) || %{}
    cli_path = config[:cli_path] || "signal-cli"
    phone = config[:phone_number]
    skip_polling = Application.get_env(:traitee, :skip_channel_polling, false)

    state = %__MODULE__{
      cli_path: cli_path,
      phone_number: phone,
      buffer: ""
    }

    cond do
      is_nil(phone) ->
        Logger.info("Signal channel not configured, skipping")
        {:ok, state}

      skip_polling ->
        Logger.info("Signal channel ready (send-only, daemon disabled)")
        {:ok, state}

      true ->
        case start_daemon(cli_path, phone) do
          {:ok, port} ->
            Logger.info("Signal channel started with signal-cli")
            {:ok, %{state | port: port}}

          {:error, reason} ->
            Logger.warning("Failed to start signal-cli: #{inspect(reason)}")
            {:ok, state}
        end
    end
  end

  @impl true
  def handle_call({:send, %{target: recipient, text: text}}, _from, state) do
    result =
      if state.port do
        command =
          Jason.encode!(%{
            jsonrpc: "2.0",
            method: "send",
            params: %{recipient: [recipient], message: text},
            id: :erlang.unique_integer([:positive])
          })

        Port.command(state.port, command <> "\n")
        :ok
      else
        {:error, :not_connected}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> to_string(data)

    {messages, remaining} = extract_json_lines(buffer)

    Enum.each(messages, fn msg ->
      handle_signal_message(msg)
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("signal-cli exited with code #{code}, restarting in 5s...")
    Process.send_after(self(), :restart_daemon, 5_000)
    {:noreply, %{state | port: nil}}
  end

  @impl true
  def handle_info(:restart_daemon, state) do
    if state.phone_number do
      case start_daemon(state.cli_path, state.phone_number) do
        {:ok, port} ->
          Logger.info("signal-cli restarted")
          {:noreply, %{state | port: port}}

        {:error, _} ->
          Process.send_after(self(), :restart_daemon, 30_000)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp start_daemon(cli_path, phone) do
    try do
      port =
        Port.open(
          {:spawn_executable, cli_path},
          [
            :binary,
            :exit_status,
            :use_stdio,
            args: ["--output=json", "daemon", "--account", phone]
          ]
        )

      {:ok, port}
    rescue
      e -> {:error, e}
    end
  end

  defp extract_json_lines(buffer) do
    lines = String.split(buffer, "\n")
    {complete, [last]} = Enum.split(lines, -1)

    parsed =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, msg} -> [msg]
          _ -> []
        end
      end)

    {parsed, last}
  end

  defp handle_signal_message(%{"envelope" => envelope}) do
    data_msg = envelope["dataMessage"]
    source = envelope["source"]

    if data_msg && data_msg["message"] && source do
      inbound =
        Channel.build_inbound(
          data_msg["message"],
          source,
          :signal,
          sender_name: envelope["sourceName"],
          channel_id: source,
          reply_to: source,
          metadata: %{timestamp: data_msg["timestamp"]}
        )

      Task.start(fn -> MessageRouter.route(inbound) end)
    end
  end

  defp handle_signal_message(_), do: :ok
end
