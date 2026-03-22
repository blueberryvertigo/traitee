defmodule Traitee.Config.HotReload do
  @moduledoc "Config hot-reload without restart."
  use GenServer

  require Logger

  @poll_interval_ms 5_000

  defstruct [:config_path, :last_mtime, :last_reload_at]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reload!() :: :ok | {:error, term()}
  def reload! do
    GenServer.call(__MODULE__, :reload)
  end

  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(Traitee.PubSub, "config:changes")
  end

  @spec last_reload() :: DateTime.t() | nil
  def last_reload do
    GenServer.call(__MODULE__, :last_reload)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    path = Traitee.config_path()
    mtime = file_mtime(path)
    schedule_poll()

    {:ok, %__MODULE__{config_path: path, last_mtime: mtime, last_reload_at: nil}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    case do_reload(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:last_reload, _from, state) do
    {:reply, state.last_reload_at, state}
  end

  @impl true
  def handle_info(:poll, state) do
    current_mtime = file_mtime(state.config_path)

    state =
      if current_mtime != state.last_mtime && current_mtime != nil do
        case do_reload(state) do
          {:ok, new_state} -> %{new_state | last_mtime: current_mtime}
          {:error, _} -> %{state | last_mtime: current_mtime}
        end
      else
        state
      end

    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp do_reload(state) do
    old_config = Traitee.Config.all()
    new_config = Traitee.Config.load!()

    changes = diff_config(old_config, new_config)

    if changes != %{} do
      Logger.info("Config reloaded, #{map_size(changes)} section(s) changed")

      Phoenix.PubSub.broadcast(
        Traitee.PubSub,
        "config:changes",
        {:config_changed, changes}
      )
    end

    {:ok, %{state | last_reload_at: DateTime.utc_now()}}
  rescue
    e ->
      Logger.warning("Config reload failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp diff_config(old, new) when is_map(old) and is_map(new) do
    all_keys = (Map.keys(old) ++ Map.keys(new)) |> Enum.uniq()

    Enum.reduce(all_keys, %{}, fn key, acc ->
      old_val = Map.get(old, key)
      new_val = Map.get(new, key)

      if old_val != new_val do
        Map.put(acc, key, %{old: old_val, new: new_val})
      else
        acc
      end
    end)
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end
end
