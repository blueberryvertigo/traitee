defmodule Traitee.LLM.Router do
  @moduledoc """
  Routes LLM requests to the configured provider with automatic failover,
  rate limiting, and usage tracking.

  Reads model config from Traitee.Config at init:
  - agent.model -> primary provider
  - agent.fallback_model -> fallback on failure
  """
  use GenServer

  alias Traitee.LLM.{Ollama, OpenAI, Provider, Types.CompletionRequest, Types.CompletionResponse}

  require Logger

  defstruct [
    :primary_provider,
    :primary_model,
    :fallback_provider,
    :fallback_model,
    :usage
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a completion request through the configured provider chain.
  Automatically falls back to the secondary provider on failure.
  """
  def complete(request) do
    GenServer.call(__MODULE__, {:complete, request}, 120_000)
  end

  @doc """
  Sends a completion with tool definitions attached.
  """
  def complete_with_tools(request, tools) do
    GenServer.call(__MODULE__, {:complete, Map.put(request, :tools, tools)}, 120_000)
  end

  @doc """
  Streams a completion, sending chunks to the calling process.
  """
  def stream(request, callback) do
    GenServer.call(__MODULE__, {:stream, request, callback}, 120_000)
  end

  @doc """
  Generates embeddings for the given texts.
  Uses OpenAI by default; falls back to Ollama.
  """
  def embed(texts) do
    GenServer.call(__MODULE__, {:embed, texts}, 60_000)
  end

  @doc """
  Returns cumulative usage statistics.
  """
  def usage_stats do
    GenServer.call(__MODULE__, :usage_stats)
  end

  @doc """
  Returns the model info for the primary model.
  """
  def model_info do
    GenServer.call(__MODULE__, :model_info)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    config = Traitee.Config.get(:agent) || %{}
    model_str = config[:model] || "openai/gpt-4o"
    fallback_str = config[:fallback_model]

    {primary_mod, primary_id} = parse_or_default(model_str)

    {fallback_mod, fallback_id} =
      if fallback_str, do: parse_or_default(fallback_str), else: {nil, nil}

    state = %__MODULE__{
      primary_provider: primary_mod,
      primary_model: primary_id,
      fallback_provider: fallback_mod,
      fallback_model: fallback_id,
      usage: %{requests: 0, tokens_in: 0, tokens_out: 0, cost: 0.0}
    }

    Logger.info("LLM Router started: primary=#{model_str}, fallback=#{fallback_str || "none"}")
    {:ok, state}
  end

  @impl true
  def handle_call({:complete, request}, _from, state) do
    req = %CompletionRequest{
      model: state.primary_model,
      messages: request[:messages] || request.messages,
      tools: request[:tools] || Map.get(request, :tools),
      temperature: request[:temperature] || Map.get(request, :temperature),
      max_tokens: request[:max_tokens] || Map.get(request, :max_tokens),
      system: request[:system] || Map.get(request, :system),
      stream: false
    }

    {result, state} = try_complete(req, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:stream, request, callback}, _from, state) do
    req = %CompletionRequest{
      model: state.primary_model,
      messages: request[:messages] || request.messages,
      temperature: request[:temperature],
      max_tokens: request[:max_tokens],
      system: request[:system],
      stream: true
    }

    result = state.primary_provider.stream(req, callback)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:embed, texts}, _from, state) do
    result =
      if function_exported?(state.primary_provider, :embed, 1) do
        case state.primary_provider.embed(texts) do
          {:ok, _} = ok -> ok
          {:error, :not_supported} -> try_fallback_embed(texts, state)
          error -> error
        end
      else
        try_fallback_embed(texts, state)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:usage_stats, _from, state) do
    {:reply, state.usage, state}
  end

  @impl true
  def handle_call(:model_info, _from, state) do
    info = state.primary_provider.model_info(state.primary_model)
    {:reply, info, state}
  end

  # -- Private --

  defp try_complete(req, state) do
    case state.primary_provider.complete(req) do
      {:ok, %CompletionResponse{} = resp} ->
        state = track_usage(state, resp)
        {{:ok, resp}, state}

      {:error, reason} ->
        Logger.warning("Primary LLM failed: #{inspect(reason)}, trying fallback...")
        try_fallback_complete(req, state, reason)
    end
  end

  defp try_fallback_complete(_req, %{fallback_provider: nil} = state, reason) do
    {{:error, reason}, state}
  end

  defp try_fallback_complete(req, state, _primary_reason) do
    fallback_req = %{req | model: state.fallback_model}

    case state.fallback_provider.complete(fallback_req) do
      {:ok, %CompletionResponse{} = resp} ->
        state = track_usage(state, resp)
        {{:ok, resp}, state}

      {:error, reason} ->
        Logger.error("Fallback LLM also failed: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  defp try_fallback_embed(texts, state) do
    cond do
      state.fallback_provider && function_exported?(state.fallback_provider, :embed, 1) ->
        state.fallback_provider.embed(texts)

      Ollama.configured?() ->
        Ollama.embed(texts)

      OpenAI.configured?() ->
        OpenAI.embed(texts)

      true ->
        {:error, :no_embedding_provider}
    end
  end

  defp track_usage(state, %CompletionResponse{usage: usage}) when is_map(usage) do
    updated = %{
      requests: state.usage.requests + 1,
      tokens_in: state.usage.tokens_in + (usage[:prompt_tokens] || usage.prompt_tokens || 0),
      tokens_out:
        state.usage.tokens_out + (usage[:completion_tokens] || usage.completion_tokens || 0),
      cost: state.usage.cost + estimate_cost(state, usage)
    }

    %{state | usage: updated}
  end

  defp track_usage(state, _), do: state

  defp estimate_cost(state, usage) do
    info = state.primary_provider.model_info(state.primary_model)

    input_cost =
      (usage[:prompt_tokens] || usage.prompt_tokens || 0) / 1000 * (info.cost_per_1k_input || 0)

    output_cost =
      (usage[:completion_tokens] || usage.completion_tokens || 0) / 1000 *
        (info.cost_per_1k_output || 0)

    input_cost + output_cost
  end

  defp parse_or_default(model_string) do
    case Provider.parse_model(model_string) do
      {:ok, {mod, id}} -> {mod, id}
      {:error, _} -> {OpenAI, "gpt-4o"}
    end
  end
end
