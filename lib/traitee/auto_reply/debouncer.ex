defmodule Traitee.AutoReply.Debouncer do
  @moduledoc "Debounce rapid messages from the same sender."
  use GenServer

  @table :traitee_debounce
  @debounce_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec debounce(String.t(), String.t()) :: :ok | :buffered
  def debounce(sender_id, message) do
    GenServer.call(__MODULE__, {:debounce, sender_id, message})
  end

  @spec flush(String.t()) :: :ok
  def flush(sender_id) do
    GenServer.cast(__MODULE__, {:flush, sender_id})
  end

  @spec get_buffered(String.t()) :: [String.t()]
  def get_buffered(sender_id) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, messages, _timer}] -> Enum.reverse(messages)
      [] -> []
    end
  end

  # -- Server --

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:debounce, sender_id, message}, _from, state) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, messages, timer_ref}] ->
        Process.cancel_timer(timer_ref)
        new_ref = schedule_flush(sender_id)
        :ets.insert(@table, {sender_id, [message | messages], new_ref})
        {:reply, :buffered, state}

      [] ->
        ref = schedule_flush(sender_id)
        :ets.insert(@table, {sender_id, [message], ref})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:flush, sender_id}, state) do
    do_flush(sender_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:flush, sender_id}, state) do
    do_flush(sender_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp do_flush(sender_id) do
    case :ets.lookup(@table, sender_id) do
      [{^sender_id, messages, _timer}] ->
        :ets.delete(@table, sender_id)
        merged = messages |> Enum.reverse() |> Enum.join("\n")

        Phoenix.PubSub.broadcast(
          Traitee.PubSub,
          "debounce:flushed",
          {:debounce_flushed, sender_id, merged}
        )

      [] ->
        :ok
    end
  end

  defp schedule_flush(sender_id) do
    Process.send_after(self(), {:flush, sender_id}, @debounce_ms)
  end
end
