defmodule Traitee.Memory.BatchEmbedder do
  @moduledoc "Batch embedding processor with concurrency control."
  use GenServer

  import Ecto.Query

  alias Traitee.LLM.Router
  alias Traitee.Memory.{Schema, Vector}

  require Logger

  @batch_size 20
  @tick_interval 5_000

  defstruct queue: :queue.new(),
            stats: %{total_embedded: 0, total_failed: 0},
            tick_scheduled: false,
            in_flight: false

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
    state = %{state | queue: :queue.in(item, state.queue)}
    {:noreply, maybe_schedule_tick(state)}
  end

  @impl true
  def handle_cast(:process_batch, state) do
    {:noreply, start_batch(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | tick_scheduled: false}
    state = start_batch(state)
    {:noreply, maybe_schedule_tick(state)}
  end

  @impl true
  def handle_info({:batch_done, embedded, failed}, state) do
    state = %{
      state
      | in_flight: false,
        stats: %{
          total_embedded: state.stats.total_embedded + embedded,
          total_failed: state.stats.total_failed + failed
        }
    }

    {:noreply, maybe_schedule_tick(state)}
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

  # Embedding is an HTTP round-trip (seconds) — run it in a Task so the
  # GenServer keeps accepting casts. At most one batch is in flight; the
  # next tick picks up whatever queued in the meantime.
  defp start_batch(%{in_flight: true} = state), do: maybe_schedule_tick(state)

  defp start_batch(state) do
    {batch, rest} = dequeue_batch(state.queue, @batch_size)

    if batch == [] do
      %{state | queue: rest}
    else
      parent = self()

      Task.start(fn ->
        {embedded, failed} = embed_batch(batch)
        send(parent, {:batch_done, embedded, failed})
      end)

      %{state | queue: rest, in_flight: true}
    end
  end

  defp embed_batch(batch) do
    texts = Enum.map(batch, fn {_type, _id, text} -> text end)

    case Router.embed(texts) do
      {:ok, embeddings} when is_list(embeddings) ->
        batch
        |> Enum.zip(embeddings)
        |> Enum.each(fn {{source_type, source_id, _text}, embedding} ->
          Vector.store(source_type, source_id, embedding)
          persist_embedding(source_type, source_id, embedding)
        end)

        {length(embeddings), 0}

      {:error, reason} ->
        Logger.warning("Batch embedding failed: #{inspect(reason)}")
        {0, length(batch)}
    end
  end

  # Mirror the ETS index into the DB embedding columns so facts/entities
  # survive a restart (Vector.reindex/0 reloads from these columns).
  defp persist_embedding(:fact, source_id, embedding) do
    persist_embedding_column(Schema.Fact, source_id, embedding)
  end

  defp persist_embedding(:entity, source_id, embedding) do
    persist_embedding_column(Schema.Entity, source_id, embedding)
  end

  defp persist_embedding(_source_type, _source_id, _embedding), do: :ok

  defp persist_embedding_column(schema, id, embedding) do
    binary =
      embedding
      |> Enum.map(&(&1 * 1.0))
      |> :erlang.term_to_binary()

    schema
    |> where([r], r.id == ^id)
    |> Traitee.Repo.update_all(set: [embedding: binary])

    :ok
  rescue
    error ->
      Logger.warning(
        "Failed to persist embedding for #{inspect({schema, id})}: #{inspect(error)}"
      )

      :ok
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

  defp maybe_schedule_tick(%{tick_scheduled: true} = state), do: state

  defp maybe_schedule_tick(state) do
    if :queue.len(state.queue) > 0 do
      Process.send_after(self(), :tick, @tick_interval)
      %{state | tick_scheduled: true}
    else
      state
    end
  end
end
