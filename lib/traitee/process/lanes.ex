defmodule Traitee.Process.Lanes do
  @moduledoc "Execution lanes for concurrency-limited process execution."
  use GenServer

  # Bump defaults to levels that actually permit concurrent multi-session
  # operation. The previous `llm: 1` would have serialized every LLM call
  # across the entire node. These values target modern LLM-API concurrency
  # ceilings and are config-overridable via `process.lanes.<lane>.max`.
  @default_lanes %{
    tool: %{max: 8},
    embed: %{max: 4},
    llm: %{max: 8}
  }

  defstruct lanes: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec acquire(atom(), non_neg_integer()) :: :ok | {:error, :busy}
  def acquire(lane, timeout_ms \\ 5_000) do
    GenServer.call(__MODULE__, {:acquire, lane, self()}, timeout_ms)
  end

  @spec release(atom()) :: :ok
  def release(lane) do
    GenServer.call(__MODULE__, {:release, lane, self()})
  end

  @spec with_lane(atom(), non_neg_integer(), (-> result)) :: result | {:error, :busy}
        when result: term()
  def with_lane(lane, timeout_ms \\ 5_000, fun) do
    case acquire(lane, timeout_ms) do
      :ok ->
        try do
          fun.()
        after
          release(lane)
        end

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    lanes =
      Map.new(@default_lanes, fn {name, config} ->
        {name, %{max: config.max, holders: MapSet.new(), waiting: :queue.new()}}
      end)

    {:ok, %__MODULE__{lanes: lanes}}
  end

  @impl true
  def handle_call({:acquire, lane, pid}, from, state) do
    lane_state = ensure_lane(state.lanes, lane)

    if MapSet.size(lane_state.holders) < lane_state.max do
      Process.monitor(pid)
      updated = %{lane_state | holders: MapSet.put(lane_state.holders, pid)}
      {:reply, :ok, put_lane(state, lane, updated)}
    else
      waiting = :queue.in(from, lane_state.waiting)
      updated = %{lane_state | waiting: waiting}
      {:noreply, put_lane(state, lane, updated)}
    end
  end

  def handle_call({:release, lane, pid}, _from, state) do
    lane_state = ensure_lane(state.lanes, lane)
    updated = do_release(lane_state, pid)
    {:reply, :ok, put_lane(state, lane, updated)}
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.new(state.lanes, fn {name, ls} ->
        {name,
         %{
           active: MapSet.size(ls.holders),
           max: ls.max,
           waiting: :queue.len(ls.waiting)
         }}
      end)

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    lanes =
      Map.new(state.lanes, fn {name, ls} ->
        if MapSet.member?(ls.holders, pid) do
          {name, do_release(ls, pid)}
        else
          {name, ls}
        end
      end)

    {:noreply, %{state | lanes: lanes}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_release(lane_state, pid) do
    holders = MapSet.delete(lane_state.holders, pid)

    case :queue.out(lane_state.waiting) do
      {{:value, from}, rest} ->
        {waiting_pid, _} = from
        Process.monitor(waiting_pid)
        GenServer.reply(from, :ok)
        %{lane_state | holders: MapSet.put(holders, waiting_pid), waiting: rest}

      {:empty, _} ->
        %{lane_state | holders: holders}
    end
  end

  defp ensure_lane(lanes, name) do
    Map.get(lanes, name, %{max: 1, holders: MapSet.new(), waiting: :queue.new()})
  end

  defp put_lane(state, name, lane_state) do
    %{state | lanes: Map.put(state.lanes, name, lane_state)}
  end
end
