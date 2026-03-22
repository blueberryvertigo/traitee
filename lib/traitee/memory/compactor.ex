defmodule Traitee.Memory.Compactor do
  @moduledoc """
  Async compaction pipeline that bridges STM -> MTM -> LTM.

  When STM evicts messages, they're sent here. The Compactor:
  1. Groups messages into chunks (configurable, default ~20)
  2. Sends each chunk to the LLM for summarization + entity extraction
  3. Stores the summary in MTM
  4. Stores extracted entities/facts in LTM
  5. Generates and stores embeddings for semantic retrieval
  """
  use GenServer

  alias Traitee.LLM.Router
  alias Traitee.Memory.{LTM, MTM, Vector}

  require Logger

  @default_chunk_size 20

  defstruct [:pending, :processing]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue messages for compaction. Messages are accumulated until
  a chunk threshold is reached, then processed asynchronously.
  """
  def compact(session_id, messages) do
    GenServer.cast(__MODULE__, {:compact, session_id, messages})
  end

  @doc """
  Forces processing of any pending messages for a session.
  """
  def flush(session_id) do
    GenServer.cast(__MODULE__, {:flush, session_id})
  end

  # -- Server --

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{pending: %{}, processing: MapSet.new()}}
  end

  @impl true
  def handle_cast({:compact, session_id, messages}, state) do
    current = Map.get(state.pending, session_id, [])
    accumulated = current ++ messages
    chunk_size = config_chunk_size()

    state =
      if length(accumulated) >= chunk_size do
        {chunk, remainder} = Enum.split(accumulated, chunk_size)
        state = %{state | pending: Map.put(state.pending, session_id, remainder)}
        process_chunk_async(session_id, chunk)
        state
      else
        %{state | pending: Map.put(state.pending, session_id, accumulated)}
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:flush, session_id}, state) do
    case Map.get(state.pending, session_id, []) do
      [] ->
        {:noreply, state}

      messages ->
        state = %{state | pending: Map.delete(state.pending, session_id)}
        process_chunk_async(session_id, messages)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:chunk_processed, session_id, result}, state) do
    state = %{state | processing: MapSet.delete(state.processing, session_id)}

    case result do
      :ok ->
        Logger.debug("Compaction complete for session #{session_id}")

      {:error, reason} ->
        Logger.warning("Compaction failed for #{session_id}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp process_chunk_async(session_id, messages) do
    parent = self()

    Task.start(fn ->
      result = process_chunk(session_id, messages)
      send(parent, {:chunk_processed, session_id, result})
    end)
  end

  defp process_chunk(session_id, messages) do
    prompt = MTM.summarization_prompt(messages)

    request = %{
      messages: [%{role: "user", content: prompt}],
      system: "You are a precise conversation analyst. Always respond with valid JSON."
    }

    with {:ok, response} <- router_mod().complete(request),
         {:ok, parsed} <- parse_extraction(response.content) do
      summary_text = parsed["summary"] || response.content
      entities = parsed["entities"] || []

      {:ok, embedding} = generate_embedding(summary_text)

      {:ok, summary} =
        MTM.store_summary(session_id, summary_text, %{
          message_count: length(messages),
          key_topics: extract_topics(entities),
          embedding: encode_embedding(embedding)
        })

      store_entities(entities, summary.id)

      if embedding do
        Vector.store(:summary, summary.id, embedding)
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning("Chunk processing failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_extraction(content) do
    content = String.trim(content)

    content =
      content
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")

    Jason.decode(content)
  rescue
    _ -> {:ok, %{"summary" => content, "entities" => []}}
  end

  defp generate_embedding(text) do
    case router_mod().embed([text]) do
      {:ok, [embedding]} -> {:ok, embedding}
      {:ok, []} -> {:ok, nil}
      {:error, _} -> {:ok, nil}
    end
  end

  defp encode_embedding(nil), do: nil

  defp encode_embedding(embedding) when is_list(embedding) do
    embedding
    |> Enum.map(&(&1 * 1.0))
    |> then(fn floats -> :erlang.term_to_binary(floats) end)
  end

  defp store_entities(entities, summary_id) do
    Enum.each(entities, fn entity_data ->
      name = entity_data["name"]
      type = entity_data["type"] || "other"
      facts = entity_data["facts"] || []
      relations = entity_data["relations"] || []

      {:ok, entity} = LTM.upsert_entity(name, type)

      Enum.each(facts, fn fact_content ->
        LTM.add_fact(entity.id, fact_content, "extracted", summary_id)
      end)

      Enum.each(relations, fn rel ->
        target_name = rel["target"] || rel[:target]
        rel_type = rel["relation_type"] || rel[:relation_type]
        desc = rel["description"] || rel[:description]

        if target_name && rel_type do
          {:ok, target} = LTM.upsert_entity(target_name, "other")
          LTM.add_relation(entity.id, target.id, rel_type, desc)
        end
      end)
    end)
  end

  defp extract_topics(entities) do
    Enum.map(entities, fn e -> e["name"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(10)
  end

  defp router_mod do
    Application.get_env(:traitee, :compactor_router, Router)
  end

  defp config_chunk_size do
    Traitee.Config.get([:memory, :mtm_chunk_size]) || @default_chunk_size
  end
end
