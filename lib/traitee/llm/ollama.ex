defmodule Traitee.LLM.Ollama do
  @moduledoc """
  Ollama provider -- local models via the Ollama HTTP API.
  """

  @behaviour Traitee.LLM.Provider

  alias Traitee.LLM.SSE
  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, ModelInfo}

  @default_base_url "http://localhost:11434"

  @impl true
  def configured? do
    case Req.get(base_url() <> "/api/tags", receive_timeout: 2_000, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def complete(%CompletionRequest{} = request) do
    body = %{
      model: request.model,
      messages: build_messages(request),
      stream: false,
      options: build_options(request)
    }

    case Req.post(base_url() <> "/api/chat",
           json: body,
           receive_timeout: 120_000,
           retry: :transient,
           retry_delay: &retry_delay/1,
           max_retries: 3
         ) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, parse_response(resp, request.model)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def stream(%CompletionRequest{} = request, callback) when is_function(callback, 1) do
    body = %{
      model: request.model,
      messages: build_messages(request),
      stream: true,
      options: build_options(request)
    }

    req =
      Req.new(
        url: base_url() <> "/api/chat",
        json: body,
        receive_timeout: 120_000,
        retry: false,
        into: fn {:data, data}, {req_acc, resp_acc} ->
          buffer = Req.Response.get_private(resp_acc, :ndjson_buffer, "")
          {lines, rest} = SSE.extract_lines(buffer <> data)
          Enum.each(lines, &handle_stream_line(&1, callback))
          {:cont, {req_acc, Req.Response.put_private(resp_acc, :ndjson_buffer, rest)}}
        end
      )

    case Req.post(req) do
      {:ok, %{status: 200}} ->
        {:ok, %CompletionResponse{content: "", model: request.model}}

      {:ok, %{status: status} = resp} ->
        {:error, {:api_error, status, Req.Response.get_private(resp, :ndjson_buffer, "")}}

      {:error, reason} ->
        {:error, {:stream_failed, reason}}
    end
  end

  defp handle_stream_line("", _callback), do: :ok

  defp handle_stream_line(line, callback) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"content" => text}}} when is_binary(text) and text != "" ->
        callback.(text)

      _ ->
        :ok
    end
  end

  @impl true
  def embed(texts) when is_list(texts) do
    results =
      Enum.map(texts, fn text ->
        body = %{model: embedding_model(), prompt: text}

        case Req.post(base_url() <> "/api/embeddings",
               json: body,
               receive_timeout: 30_000,
               retry: false
             ) do
          {:ok, %{status: 200, body: %{"embedding" => embedding}}} -> {:ok, embedding}
          other -> {:error, other}
        end
      end)

    errors = Enum.filter(results, fn {status, _} -> status == :error end)

    if errors == [] do
      {:ok, Enum.map(results, fn {:ok, emb} -> emb end)}
    else
      {:error, {:embed_failed, errors}}
    end
  end

  @impl true
  def model_info(model_id) do
    %ModelInfo{
      id: model_id,
      provider: :ollama,
      context_window: 32_768,
      max_output_tokens: 8_192,
      cost_per_1k_input: 0.0,
      cost_per_1k_output: 0.0,
      supports_tools: false,
      supports_vision: false
    }
  end

  # -- Private --

  defp build_messages(%CompletionRequest{} = req) do
    messages = Enum.map(req.messages, &format_message/1)

    if req.system do
      [%{role: "system", content: req.system} | messages]
    else
      messages
    end
  end

  defp format_message(%Traitee.LLM.Types.Message{} = msg) do
    %{role: msg.role, content: msg.content}
  end

  defp format_message(msg) when is_map(msg) do
    %{role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]}
  end

  defp parse_response(%{"message" => message} = resp, model) do
    eval_count = get_in(resp, ["eval_count"]) || 0
    prompt_eval_count = get_in(resp, ["prompt_eval_count"]) || 0

    %CompletionResponse{
      content: message["content"],
      tool_calls: nil,
      model: model,
      finish_reason: "stop",
      usage: %{
        prompt_tokens: prompt_eval_count,
        completion_tokens: eval_count,
        total_tokens: prompt_eval_count + eval_count
      }
    }
  end

  defp build_options(%CompletionRequest{} = req) do
    opts = %{}
    opts = if req.temperature, do: Map.put(opts, :temperature, req.temperature), else: opts
    opts = if req.max_tokens, do: Map.put(opts, :num_predict, req.max_tokens), else: opts
    opts
  end

  defp base_url do
    System.get_env("OLLAMA_HOST") ||
      Traitee.Config.get([:agent, :ollama_host]) ||
      @default_base_url
  end

  defp embedding_model do
    Traitee.Config.get([:memory, :embedding_model]) || "nomic-embed-text"
  end

  defp retry_delay(attempt), do: Integer.pow(2, attempt) * 1_000
end
