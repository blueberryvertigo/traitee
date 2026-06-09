defmodule Traitee.AutoReply.Debouncer do
  @moduledoc """
  Debounce rapid messages from the same sender.

  The first message in a window passes through (`:ok`) and is processed
  normally. Messages arriving within the debounce window are buffered
  (`:buffered`); when the window closes the buffered inbound maps are
  merged into a single message and re-injected into `Traitee.Router.route/1`
  so they are processed instead of dropped.
  """
  use GenServer

  @table :traitee_debounce
  @debounce_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Debounce an inbound message map (the normalized shape produced by the
  channels: `%{text: ..., sender_id: ..., channel_type: ..., ...}`).
  Returns `:ok` when the message should be processed now, `:buffered`
  when it has been queued for a merged flush.
  """
  @spec debounce(String.t(), map()) :: :ok | :buffered
  def debounce(sender_id, inbound) do
    GenServer.call(__MODULE__, {:debounce, sender_id, inbound})
  end

  @spec flush(String.t()) :: :ok
  def flush(sender_id) do
    GenServer.cast(__MODULE__, {:flush, sender_id})
  end

  @spec get_buffered(String.t()) :: [String.t()]
  def get_buffered(sender_id) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, buffer, _timer, _gen}] ->
        buffer |> Enum.reverse() |> Enum.map(&buffered_text/1)

      [] ->
        []
    end
  end

  # -- Server --

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:debounce, sender_id, inbound}, _from, state) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, buffer, timer_ref, gen}] ->
        # Within the window: buffer this message and extend the window.
        # The generation counter makes any already-mailboxed :flush from
        # the cancelled timer a no-op (cancel_timer can race delivery).
        Process.cancel_timer(timer_ref)
        new_gen = gen + 1
        new_ref = schedule_flush(sender_id, new_gen)
        :ets.insert(@table, {sender_id, [inbound | buffer], new_ref, new_gen})
        {:reply, :buffered, state}

      [] ->
        # First message: let it pass through unbuffered (it is processed
        # by the caller) and just open the window.
        ref = schedule_flush(sender_id, 0)
        :ets.insert(@table, {sender_id, [], ref, 0})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:flush, sender_id}, state) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, buffer, timer_ref, _gen}] ->
        Process.cancel_timer(timer_ref)
        :ets.delete(@table, sender_id)
        flush_buffer(buffer)

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:flush, sender_id, gen}, state) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, buffer, _timer, ^gen}] ->
        :ets.delete(@table, sender_id)
        flush_buffer(buffer)

      _ ->
        # Stale timer from a superseded generation (or already flushed).
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp flush_buffer([]), do: :ok

  defp flush_buffer(buffer) do
    inbounds = Enum.reverse(buffer)
    merged = Enum.map_join(inbounds, "\n", &buffered_text/1)
    latest = List.last(inbounds)

    if is_map(latest) do
      # Re-inject the merged message into the router so buffered messages
      # are actually processed (they were previously broadcast to a topic
      # nothing subscribed to, i.e. permanently lost).
      Task.start(fn ->
        try do
          Traitee.Router.route(Map.put(latest, :text, merged))
        rescue
          _ -> :ok
        end
      end)
    end

    :ok
  end

  defp buffered_text(%{text: text}), do: text
  defp buffered_text(other) when is_binary(other), do: other
  defp buffered_text(_), do: ""

  defp schedule_flush(sender_id, gen) do
    Process.send_after(self(), {:flush, sender_id, gen}, @debounce_ms)
  end
end
