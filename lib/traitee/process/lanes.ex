defmodule Traitee.Process.Lanes do
  @moduledoc "Execution lanes for concurrency-limited process execution."
  use GenServer

  alias Traitee.Config

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
    # The server replies {:error, :busy} at the deadline, so give the
    # call a grace period — the server-side reply must win over the
    # client-side exit (which would crash the caller mid-turn).
    GenServer.call(__MODULE__, {:acquire, lane, self(), timeout_ms}, timeout_ms + 1_000)
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
        {name, %{max: configured_max(name, config.max), holders: %{}, waiting: :queue.new()}}
      end)

    {:ok, %__MODULE__{lanes: lanes}}
  end

  @impl true
  def handle_call({:acquire, lane, pid, timeout_ms}, from, state) do
    lane_state = ensure_lane(state.lanes, lane)

    if map_size(lane_state.holders) < lane_state.max do
      {:reply, :ok, put_lane(state, lane, add_holder(lane_state, pid))}
    else
      waiter = %{
        from: from,
        pid: pid,
        ref: Process.monitor(pid),
        deadline: System.monotonic_time(:millisecond) + timeout_ms
      }

      Process.send_after(self(), {:waiter_deadline, lane, from}, timeout_ms)
      updated = %{lane_state | waiting: :queue.in(waiter, lane_state.waiting)}
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
           active: map_size(ls.holders),
           max: ls.max,
           waiting: :queue.len(ls.waiting)
         }}
      end)

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    lanes =
      Map.new(state.lanes, fn {name, ls} ->
        {name, handle_down(ls, ref, pid)}
      end)

    {:noreply, %{state | lanes: lanes}}
  end

  # A waiter hit its deadline while still queued: remove it and reply
  # {:error, :busy} so the caller's GenServer.call returns instead of
  # exiting, and so a later do_release can't promote a stale `from`.
  def handle_info({:waiter_deadline, lane, from}, state) do
    lane_state = ensure_lane(state.lanes, lane)

    {expired, kept} =
      lane_state.waiting
      |> :queue.to_list()
      |> Enum.split_with(&(&1.from == from))

    Enum.each(expired, fn waiter ->
      Process.demonitor(waiter.ref, [:flush])
      GenServer.reply(waiter.from, {:error, :busy})
    end)

    updated = %{lane_state | waiting: :queue.from_list(kept)}
    {:noreply, put_lane(state, lane, updated)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_down(lane_state, ref, pid) do
    if Map.get(lane_state.holders, pid) == ref do
      do_release(lane_state, pid)
    else
      waiting =
        lane_state.waiting
        |> :queue.to_list()
        |> Enum.reject(&(&1.ref == ref))
        |> :queue.from_list()

      %{lane_state | waiting: waiting}
    end
  end

  defp add_holder(lane_state, pid) do
    holders = Map.put_new_lazy(lane_state.holders, pid, fn -> Process.monitor(pid) end)
    %{lane_state | holders: holders}
  end

  defp do_release(lane_state, pid) do
    holders =
      case Map.pop(lane_state.holders, pid) do
        {nil, holders} ->
          holders

        {ref, holders} ->
          Process.demonitor(ref, [:flush])
          holders
      end

    promote_waiter(%{lane_state | holders: holders})
  end

  # Hand the freed slot to the next live, non-expired waiter. Expired or
  # dead waiters are dropped (their monitor demonitored) — replying to
  # them would insert a phantom holder for a caller that already gave up.
  defp promote_waiter(lane_state) do
    case :queue.out(lane_state.waiting) do
      {{:value, waiter}, rest} ->
        next = %{lane_state | waiting: rest}
        now = System.monotonic_time(:millisecond)

        cond do
          not Process.alive?(waiter.pid) ->
            Process.demonitor(waiter.ref, [:flush])
            promote_waiter(next)

          waiter.deadline <= now ->
            Process.demonitor(waiter.ref, [:flush])
            GenServer.reply(waiter.from, {:error, :busy})
            promote_waiter(next)

          true ->
            GenServer.reply(waiter.from, :ok)
            %{next | holders: Map.put(next.holders, waiter.pid, waiter.ref)}
        end

      {:empty, _} ->
        lane_state
    end
  end

  defp ensure_lane(lanes, name) do
    Map.get(lanes, name, %{max: 1, holders: %{}, waiting: :queue.new()})
  end

  defp put_lane(state, name, lane_state) do
    %{state | lanes: Map.put(state.lanes, name, lane_state)}
  end

  defp configured_max(name, default) do
    case Config.get([:process, :lanes]) do
      %{} = lanes_config -> lane_max(lanes_config, name, default)
      _ -> default
    end
  rescue
    _ -> default
  end

  defp lane_max(lanes_config, name, default) do
    lane_config = Map.get(lanes_config, name) || Map.get(lanes_config, to_string(name)) || %{}

    max =
      if is_map(lane_config) do
        Map.get(lane_config, :max) || Map.get(lane_config, "max")
      end

    if is_integer(max) and max > 0, do: max, else: default
  end
end
