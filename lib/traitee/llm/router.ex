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
  The HTTP call runs in the caller's process for concurrency.
  """
  def complete(request) do
    {primary, fallback} = resolve()
    req = build_request(request, primary.model)

    case do_complete(req, primary, fallback) do
      {:ok, resp} ->
        track_usage(resp)
        {:ok, resp}

      error ->
        error
    end
  end

  @doc """
  Sends a completion with tool definitions attached.
  """
  def complete_with_tools(request, tools) do
    complete(Map.put(request, :tools, tools))
  end

  @doc """
  Streams a completion, sending chunks to the calling process.
  """
  def stream(request, callback) do
    {primary, _fallback} = resolve()

    req = %CompletionRequest{
      model: primary.model,
      messages: request[:messages] || request.messages,
      temperature: request[:temperature],
      max_tokens: request[:max_tokens],
      system: request[:system],
      stream: true
    }

    primary.provider.stream(req, callback)
  end

  @doc """
  Generates embeddings for the given texts.
  Uses OpenAI by default; falls back to Ollama.
  """
  def embed(texts) do
    GenServer.call(__MODULE__, {:embed, texts}, 60_000)
  end

  @doc """
  Returns provider routing info. Fast GenServer.call (no HTTP).
  """
  def resolve do
    GenServer.call(__MODULE__, :resolve)
  end

  @doc """
  Records usage stats from a completion response. Fire-and-forget.
  """
  def track_usage(%CompletionResponse{} = resp) do
    GenServer.cast(__MODULE__, {:track_usage, resp})
  end

  def track_usage(_), do: :ok

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
  def handle_call(:resolve, _from, state) do
    primary = %{provider: state.primary_provider, model: state.primary_model}

    fallback =
      if state.fallback_provider,
        do: %{provider: state.fallback_provider, model: state.fallback_model},
        else: nil

    {:reply, {primary, fallback}, state}
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

  @impl true
  def handle_cast({:track_usage, %CompletionResponse{} = resp}, state) do
    {:noreply, do_track_usage(state, resp)}
  end

  # -- Private: Concurrent completion (runs in caller's process) --

  defp build_request(request, model) do
    %CompletionRequest{
      model: model,
      messages: request[:messages] || request.messages,
      tools: request[:tools] || Map.get(request, :tools),
      temperature: request[:temperature] || Map.get(request, :temperature),
      max_tokens: request[:max_tokens] || Map.get(request, :max_tokens),
      system: request[:system] || Map.get(request, :system),
      stream: false
    }
  end

  defp do_complete(req, primary, fallback) do
    case primary.provider.complete(req) do
      {:ok, %CompletionResponse{} = resp} ->
        {:ok, resp}

      {:error, reason} ->
        Logger.warning("Primary LLM failed: #{inspect(reason)}, trying fallback...")
        try_fallback_complete(req, fallback, reason)
    end
  end

  defp try_fallback_complete(_req, nil, reason), do: {:error, reason}

  defp try_fallback_complete(req, fallback, _primary_reason) do
    fallback_req = %{req | model: fallback.model}

    case fallback.provider.complete(fallback_req) do
      {:ok, %CompletionResponse{} = resp} ->
        {:ok, resp}

      {:error, reason} ->
        Logger.error("Fallback LLM also failed: #{inspect(reason)}")
        {:error, reason}
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

  defp do_track_usage(state, %CompletionResponse{usage: usage}) when is_map(usage) do
    updated = %{
      requests: state.usage.requests + 1,
      tokens_in: state.usage.tokens_in + (usage[:prompt_tokens] || usage.prompt_tokens || 0),
      tokens_out:
        state.usage.tokens_out + (usage[:completion_tokens] || usage.completion_tokens || 0),
      cost: state.usage.cost + estimate_cost(state, usage)
    }

    %{state | usage: updated}
  end

  defp do_track_usage(state, _), do: state

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
