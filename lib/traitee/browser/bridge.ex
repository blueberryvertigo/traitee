defmodule Traitee.Browser.Bridge do
  @moduledoc """
  GenServer managing a Node.js Playwright bridge process via Elixir Port.
  Lazy-starts the browser on first command. Auto-restarts on crash.
  """
  use GenServer

  require Logger

  @default_timeout 30_000

  defstruct [:port, :buffer, :pending, :cmd_counter]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a command to the browser bridge. Returns {:ok, result} or {:error, reason}."
  def call(action, params \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:command, action, params}, timeout + 5_000)
  end

  @doc "Check if the bridge process is running."
  def alive? do
    GenServer.call(__MODULE__, :alive?)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      port: nil,
      buffer: "",
      pending: %{},
      cmd_counter: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:command, action, params}, from, state) do
    state =
      try do
        ensure_port(state)
      rescue
        e ->
          Logger.error("Browser bridge failed to start: #{Exception.message(e)}")
          state
      end

    if state.port == nil do
      {:reply, {:error, "Browser bridge failed to start"}, state}
    else
      cmd_id = state.cmd_counter + 1
      state = %{state | cmd_counter: cmd_id}

      command = Jason.encode!(%{id: cmd_id, action: to_string(action), params: params})

      try do
        Port.command(state.port, command <> "\n")

        timer_ref = Process.send_after(self(), {:timeout, cmd_id}, @default_timeout)
        pending = Map.put(state.pending, cmd_id, {from, timer_ref})

        {:noreply, %{state | pending: pending}}
      rescue
        e ->
          Logger.error("Browser bridge port write failed: #{inspect(e)}")
          {:reply, {:error, "Browser bridge crashed — port closed"}, %{state | port: nil}}
      end
    end
  end

  @impl true
  def handle_call(:alive?, _from, state) do
    {:reply, state.port != nil, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> to_string(data)

    {lines, remaining} = split_lines(buffer)

    state =
      Enum.reduce(lines, %{state | buffer: remaining}, fn line, acc ->
        handle_response(line, acc)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("Browser bridge port exited: #{inspect(reason)}")
    drain_pending(state.pending, "Browser bridge port died (#{inspect(reason)})")
    {:noreply, %{state | port: nil, buffer: "", pending: %{}}}
  end

  @impl true
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("Browser bridge process exited with code #{code}")
    drain_pending(state.pending, "Browser bridge crashed (exit code #{code})")
    {:noreply, %{state | port: nil, buffer: "", pending: %{}}}
  end

  @impl true
  def handle_info({:timeout, cmd_id}, state) do
    case Map.pop(state.pending, cmd_id) do
      {{from, _timer_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port do
      try do
        Port.command(state.port, Jason.encode!(%{id: 0, action: "close", params: %{}}) <> "\n")
        Process.sleep(500)
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  @ready_timeout 5_000

  defp wait_for_ready(port) do
    receive do
      {^port, {:data, data}} ->
        case Jason.decode(data) do
          {:ok, %{"id" => 0, "ok" => true}} -> :ok
          _ -> {:error, "unexpected startup message: #{inspect(data)}"}
        end

      {^port, {:exit_status, code}} ->
        {:error, "node exited with code #{code} during startup"}

      {:EXIT, ^port, reason} ->
        {:error, "port crashed during startup: #{inspect(reason)}"}
    after
      @ready_timeout ->
        {:error, "bridge did not send ready signal within #{@ready_timeout}ms"}
    end
  end

  defp safely_close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp drain_pending(pending, reason) do
    for {_id, {from, timer_ref}} <- pending do
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end
  end

  defp ensure_port(%{port: nil} = state) do
    bridge_dir = bridge_dir()
    bridge_path = Path.join(bridge_dir, "bridge.js")
    node_bin = System.find_executable("node")

    cond do
      node_bin == nil ->
        Logger.error("Node.js not found. Browser bridge requires Node.js.")
        state

      not File.exists?(bridge_path) ->
        Logger.error("Browser bridge script not found at #{bridge_path}")
        state

      not File.dir?(Path.join(bridge_dir, "node_modules")) ->
        Logger.error(
          "Browser bridge dependencies not installed. Run: cd #{bridge_dir} && npm install && npx playwright install chromium"
        )

        state

      true ->
        port =
          Port.open({:spawn_executable, node_bin}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:args, [bridge_path]},
            {:cd, bridge_dir}
          ])

        case wait_for_ready(port) do
          :ok ->
            Logger.info("Browser bridge ready (port: #{inspect(port)})")
            %{state | port: port, buffer: ""}

          {:error, reason} ->
            Logger.error("Browser bridge failed to start: #{reason}")
            safely_close_port(port)
            state
        end
    end
  end

  defp ensure_port(state), do: state

  defp bridge_dir do
    source = Path.join([File.cwd!(), "priv", "browser"])

    if File.dir?(source) do
      source
    else
      app_dir = Application.app_dir(:traitee, "priv")
      Path.join(app_dir, "browser")
    end
  rescue
    _ -> Path.join([File.cwd!(), "priv", "browser"])
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")

    case parts do
      [single] -> {[], single}
      lines -> {Enum.slice(lines, 0..-2//1), List.last(lines)}
    end
  end

  defp handle_response(line, state) do
    line = String.trim(line)

    if line == "" do
      state
    else
      case Jason.decode(line) do
        {:ok, %{"id" => id} = response} ->
          dispatch_response(state, id, response)

        {:ok, _} ->
          state

        {:error, _} ->
          unless String.starts_with?(line, "browser-bridge") do
            Logger.debug("Browser bridge stderr: #{line}")
          end

          state
      end
    end
  end

  defp dispatch_response(state, id, response) do
    case Map.pop(state.pending, id) do
      {{from, timer_ref}, pending} ->
        Process.cancel_timer(timer_ref)

        reply =
          if response["ok"], do: {:ok, response["result"]}, else: {:error, response["error"]}

        GenServer.reply(from, reply)
        %{state | pending: pending}

      {nil, _} ->
        state
    end
  end
end
