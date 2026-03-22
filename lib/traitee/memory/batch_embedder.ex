defmodule Traitee.Memory.BatchEmbedder do
  @moduledoc "Batch embedding processor with concurrency control."
  use GenServer

  alias Traitee.LLM.Router
  alias Traitee.Memory.Vector

  require Logger

  @batch_size 20
  @tick_interval 5_000

  defstruct queue: :queue.new(), stats: %{total_embedded: 0, total_failed: 0}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue an item for embedding: {source_type, source_id, text}"
  def enqueue(source_type, source_id, text) do
    GenServer.cast(__MODULE__, {:enqueue, {source_type, source_id, text}})
  end

  @doc "Force-process the current batch immediately."
  def process_batch do
    GenServer.cast(__MODULE__, :process_batch)
  end

  @doc "Returns queue size and cumulative stats."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:enqueue, item}, state) do
    new_queue = :queue.in(item, state.queue)
    state = %{state | queue: new_queue}
    maybe_schedule_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:process_batch, state) do
    {:noreply, do_process(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_process(state)
    maybe_schedule_tick(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    info =
      Map.merge(state.stats, %{queue_size: :queue.len(state.queue)})

    {:reply, info, state}
  end

  # -- Private --

  defp do_process(state) do
    {batch, rest} = dequeue_batch(state.queue, @batch_size)

    if batch == [] do
      %{state | queue: rest}
    else
      texts = Enum.map(batch, fn {_type, _id, text} -> text end)

      state =
        case Router.embed(texts) do
          {:ok, embeddings} when is_list(embeddings) ->
            batch
            |> Enum.zip(embeddings)
            |> Enum.each(fn {{source_type, source_id, _text}, embedding} ->
              Vector.store(source_type, source_id, embedding)
            end)

            update_stats(state, rest, length(embeddings), 0)

          {:error, reason} ->
            Logger.warning("Batch embedding failed: #{inspect(reason)}")
            update_stats(state, rest, 0, length(batch))
        end

      state
    end
  end

  defp dequeue_batch(queue, n) do
    dequeue_batch(queue, n, [])
  end

  defp dequeue_batch(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp dequeue_batch(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> dequeue_batch(rest, n - 1, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end

  defp update_stats(state, queue, embedded, failed) do
    %{
      state
      | queue: queue,
        stats: %{
          total_embedded: state.stats.total_embedded + embedded,
          total_failed: state.stats.total_failed + failed
        }
    }
  end

  defp maybe_schedule_tick(state) do
    if :queue.len(state.queue) > 0 do
      Process.send_after(self(), :tick, @tick_interval)
    end
  end
end
