defmodule Traitee.Memory.STM do
  @moduledoc """
  Short-Term Memory -- ETS-backed ring buffer per session.

  Stores the most recent N messages (default 50) at full fidelity.
  When capacity is exceeded, oldest messages are evicted and sent
  to the Compactor for mid-term summarization.

  Each session has its own ETS table for lock-free reads.
  """

  alias Traitee.Memory.{Compactor, Schema.Message}
  alias Traitee.LLM.Tokenizer

  require Logger

  @default_capacity 50

  @doc """
  Initializes STM storage for a session. Creates an ETS table
  and optionally rehydrates from the database.
  """
  def init(session_id, opts \\ []) do
    table = table_name(session_id)
    capacity = opts[:capacity] || config_capacity()

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:ordered_set, :named_table, :public, read_concurrency: true])
    end

    if opts[:rehydrate] != false do
      rehydrate(session_id, table, capacity)
    end

    %{table: table, session_id: session_id, capacity: capacity, counter: next_counter(table)}
  end

  @doc """
  Adds a message to the STM buffer. If capacity is exceeded,
  evicts the oldest messages and sends them to the Compactor.
  """
  def push(stm_state, role, content, opts \\ []) do
    %{table: table, session_id: session_id, capacity: capacity, counter: counter} = stm_state

    token_count = Tokenizer.count_tokens(content)

    entry = %{
      id: counter,
      role: role,
      content: content,
      channel: opts[:channel],
      token_count: token_count,
      timestamp: DateTime.utc_now()
    }

    :ets.insert(table, {counter, entry})

    persist_message(session_id, entry)

    stm_state = %{stm_state | counter: counter + 1}

    case check_eviction(table, capacity) do
      {:evict, evicted} ->
        Compactor.compact(session_id, evicted)
        stm_state

      :ok ->
        stm_state
    end
  end

  @doc """
  Returns all messages in the STM buffer, ordered oldest to newest.
  """
  def get_messages(stm_state) do
    %{table: table} = stm_state

    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  @doc """
  Returns the N most recent messages.
  """
  def get_recent(stm_state, n) do
    stm_state
    |> get_messages()
    |> Enum.take(-n)
  end

  @doc """
  Returns the total token count of all messages in the buffer.
  """
  def total_tokens(stm_state) do
    stm_state
    |> get_messages()
    |> Enum.reduce(0, fn msg, acc -> acc + (msg.token_count || 0) end)
  end

  @doc """
  Returns the number of messages in the buffer.
  """
  def count(stm_state) do
    :ets.info(stm_state.table, :size)
  end

  @doc """
  Clears all messages from the STM buffer.
  """
  def clear(stm_state) do
    :ets.delete_all_objects(stm_state.table)
    %{stm_state | counter: 0}
  end

  @doc """
  Destroys the ETS table for a session.
  """
  def destroy(stm_state) do
    if :ets.whereis(stm_state.table) != :undefined do
      :ets.delete(stm_state.table)
    end

    :ok
  end

  # -- Private --

  defp check_eviction(table, capacity) do
    size = :ets.info(table, :size)

    if size > capacity do
      overage = size - capacity
      chunk_size = max(overage, div(capacity, 5))

      evicted =
        table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.take(chunk_size)
        |> Enum.map(fn {k, v} ->
          :ets.delete(table, k)
          v
        end)

      {:evict, evicted}
    else
      :ok
    end
  end

  defp rehydrate(session_id, table, capacity) do
    import Ecto.Query

    messages =
      Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], desc: m.inserted_at)
      |> limit(^capacity)
      |> Traitee.Repo.all()
      |> Enum.reverse()

    messages
    |> Enum.with_index()
    |> Enum.each(fn {msg, idx} ->
      entry = %{
        id: idx,
        role: msg.role,
        content: msg.content,
        channel: msg.channel,
        token_count: msg.token_count,
        timestamp: msg.inserted_at
      }

      :ets.insert(table, {idx, entry})
    end)
  end

  defp persist_message(session_id, entry) do
    Task.start(fn ->
      channel = if entry[:channel], do: to_string(entry[:channel])

      result =
        %Message{}
        |> Message.changeset(%{
          session_id: session_id,
          role: entry.role,
          content: entry.content,
          channel: channel,
          token_count: entry.token_count
        })
        |> Traitee.Repo.insert()

      case result do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "Failed to persist message for #{session_id}: #{inspect(changeset.errors)}"
          )
      end
    end)
  end

  defp table_name(session_id) do
    :"traitee_stm_#{session_id}"
  end

  defp next_counter(table) do
    case :ets.info(table, :size) do
      0 ->
        0

      _ ->
        table
        |> :ets.tab2list()
        |> Enum.max_by(fn {k, _} -> k end)
        |> elem(0)
        |> Kernel.+(1)
    end
  end

  defp config_capacity do
    Traitee.Config.get([:memory, :stm_capacity]) || @default_capacity
  end
end
