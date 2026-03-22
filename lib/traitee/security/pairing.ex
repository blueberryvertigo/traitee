defmodule Traitee.Security.Pairing do
  @moduledoc "DM pairing - unknown senders get a pairing code that must be approved."
  use GenServer

  require Logger

  @code_length 6
  @expiry_ms :timer.minutes(10)
  @cleanup_interval_ms :timer.seconds(60)
  @approved_file "approved_senders.json"

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec check_sender(String.t(), atom()) :: :approved | {:pending, String.t()}
  def check_sender(sender_id, channel_type) do
    GenServer.call(__MODULE__, {:check, sender_id, channel_type})
  end

  @spec approve(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def approve(code) do
    GenServer.call(__MODULE__, {:approve, code})
  end

  @spec revoke(String.t()) :: :ok
  def revoke(sender_id) do
    GenServer.call(__MODULE__, {:revoke, sender_id})
  end

  @spec list_approved() :: [String.t()]
  def list_approved do
    GenServer.call(__MODULE__, :list_approved)
  end

  @spec list_pending() :: [map()]
  def list_pending do
    GenServer.call(__MODULE__, :list_pending)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    approved = load_approved()
    schedule_cleanup()
    {:ok, %{pending: %{}, approved: approved}}
  end

  @impl true
  def handle_call({:check, sender_id, channel_type}, _from, state) do
    key = composite_key(channel_type, sender_id)

    cond do
      MapSet.member?(state.approved, key) ->
        {:reply, :approved, state}

      code = find_pending_code(state.pending, key) ->
        {:reply, {:pending, code}, state}

      true ->
        code = generate_code()

        entry = %{
          key: key,
          sender_id: sender_id,
          channel: channel_type,
          timestamp: System.monotonic_time(:millisecond)
        }

        pending = Map.put(state.pending, code, entry)
        Logger.info("Pairing code #{code} generated for #{sender_id} on #{channel_type}")
        {:reply, {:pending, code}, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_call({:approve, code}, _from, state) do
    case Map.pop(state.pending, code) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {%{key: key, sender_id: sender_id, channel: channel}, pending} ->
        approved = MapSet.put(state.approved, key)
        persist_approved(approved)
        Logger.info("Sender #{sender_id} approved on #{channel} via code #{code}")
        {:reply, {:ok, key}, %{state | pending: pending, approved: approved}}
    end
  end

  @impl true
  def handle_call({:revoke, key}, _from, state) do
    approved = MapSet.delete(state.approved, key)
    persist_approved(approved)
    {:reply, :ok, %{state | approved: approved}}
  end

  @impl true
  def handle_call(:list_approved, _from, state) do
    {:reply, MapSet.to_list(state.approved), state}
  end

  @impl true
  def handle_call(:list_pending, _from, state) do
    list =
      Enum.map(state.pending, fn {code, entry} ->
        Map.put(entry, :code, code)
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    pending =
      state.pending
      |> Enum.reject(fn {_code, %{timestamp: ts}} -> now - ts > @expiry_ms end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | pending: pending}}
  end

  # -- Private --

  defp find_pending_code(pending, key) do
    Enum.find_value(pending, fn {code, %{key: k}} ->
      if k == key, do: code
    end)
  end

  defp composite_key(channel_type, sender_id) do
    "#{channel_type}:#{sender_id}"
  end

  defp generate_code do
    @code_length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, @code_length)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp approved_path do
    Path.join(Traitee.data_dir(), @approved_file)
  end

  defp load_approved do
    case File.read(approved_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, list} when is_list(list) ->
            migrated = migrate_legacy_keys(list)
            if migrated != list, do: persist_approved(MapSet.new(migrated))
            MapSet.new(migrated)

          _ ->
            MapSet.new()
        end

      {:error, _} ->
        MapSet.new()
    end
  end

  defp migrate_legacy_keys(list) do
    Enum.map(list, fn entry ->
      if String.contains?(entry, ":"), do: entry, else: "telegram:#{entry}"
    end)
  end

  defp persist_approved(approved) do
    data = approved |> MapSet.to_list() |> Jason.encode!()
    File.write!(approved_path(), data)
  end
end
