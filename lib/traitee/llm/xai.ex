defmodule Traitee.LLM.XAI do
  @moduledoc """
  xAI provider -- Grok models via the OpenAI-compatible API at api.x.ai/v1.
  """

  @behaviour Traitee.LLM.Provider

  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, ModelInfo}

  @api_base "https://api.x.ai/v1"

  @models %{
    "grok-4-1-fast-non-reasoning" => %ModelInfo{
      id: "grok-4-1-fast-non-reasoning",
      provider: :xai,
      context_window: 2_000_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.0002,
      cost_per_1k_output: 0.0005,
      supports_tools: true,
      supports_vision: true
    },
    "grok-4-1-fast-reasoning" => %ModelInfo{
      id: "grok-4-1-fast-reasoning",
      provider: :xai,
      context_window: 2_000_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.0002,
      cost_per_1k_output: 0.0005,
      supports_tools: true,
      supports_vision: true
    },
    "grok-4-0709" => %ModelInfo{
      id: "grok-4-0709",
      provider: :xai,
      context_window: 256_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.003,
      cost_per_1k_output: 0.015,
      supports_tools: true,
      supports_vision: true
    }
  }

  @impl true
  def configured? do
    api_key() != nil
  end

  @impl true
  def complete(%CompletionRequest{} = request) do
    body = build_request_body(request)

    case post("/chat/completions", body) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, parse_response(resp)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Lightweight completion that bypasses the Provider struct machinery.
  Used by the judge for fast, simple classification calls.
  """
  def quick_complete(messages, opts \\ []) do
    model = opts[:model] || "grok-4-1-fast-non-reasoning"
    temperature = opts[:temperature] || 0
    max_tokens = opts[:max_tokens] || 256
    timeout = opts[:timeout] || 3_000

    body = %{
      model: model,
      messages: messages,
      temperature: temperature,
      max_tokens: max_tokens
    }

    req =
      Req.new(
        headers: [
          {"authorization", "Bearer #{api_key()}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        retry: false
      )

    case Req.post(req, url: "#{@api_base}/chat/completions", json: body) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def stream(%CompletionRequest{} = request, callback) when is_function(callback, 1) do
    body = build_request_body(%{request | stream: true})

    req =
      build_req()
      |> Req.merge(
        url: "#{@api_base}/chat/completions",
        json: body,
        into: fn {:data, data}, acc ->
          for line <- String.split(data, "\n", trim: true) do
            case line do
              "data: [DONE]" ->
                :ok

              "data: " <> json ->
                case Jason.decode(json) do
                  {:ok, %{"choices" => [%{"delta" => %{"content" => c}}]}} when is_binary(c) ->
                    callback.(c)

                  _ ->
                    :ok
                end

              _ ->
                :ok
            end
          end

          {:cont, acc}
        end
      )

    case Req.post(req) do
      {:ok, _resp} -> {:ok, %CompletionResponse{content: "", model: request.model}}
      {:error, reason} -> {:error, {:stream_failed, reason}}
    end
  end

  @impl true
  def embed(_texts) do
    {:error, :not_supported}
  end

  @impl true
  def model_info(model_id) do
    Map.get(@models, model_id, %ModelInfo{
      id: model_id,
      provider: :xai,
      context_window: 131_072,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.0002,
      cost_per_1k_output: 0.0005,
      supports_tools: true,
      supports_vision: false
    })
  end

  # -- Private --

  defp build_request_body(%CompletionRequest{} = req) do
    body = %{
      model: req.model,
      messages: Enum.map(req.messages, &format_message/1)
    }

    body
    |> maybe_put(:temperature, req.temperature)
    |> maybe_put(:max_tokens, req.max_tokens)
    |> maybe_put(:stream, req.stream)
    |> maybe_put_tools(req.tools)
  end

  defp format_message(%Traitee.LLM.Types.Message{} = msg) do
    base = %{role: msg.role, content: msg.content}

    base
    |> maybe_put(:tool_calls, msg.tool_calls)
    |> maybe_put(:tool_call_id, msg.tool_call_id)
    |> maybe_put(:name, msg.name)
  end

  defp format_message(msg) when is_map(msg), do: msg

  defp parse_response(%{"choices" => [choice | _]} = resp) do
    message = choice["message"]
    usage = resp["usage"] || %{}

    %CompletionResponse{
      content: message["content"],
      tool_calls: message["tool_calls"],
      model: resp["model"],
      finish_reason: choice["finish_reason"],
      usage: %{
        prompt_tokens: usage["prompt_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0,
        total_tokens: usage["total_tokens"] || 0
      }
    }
  end

  defp post(path, body) do
    build_req()
    |> Req.post(url: "#{@api_base}#{path}", json: body)
  end

  defp build_req do
    Req.new(
      headers: [
        {"authorization", "Bearer #{api_key()}"},
        {"content-type", "application/json"}
      ],
      receive_timeout: 120_000,
      retry: false
    )
  end

  defp api_key do
    Application.get_env(:traitee, :xai_api_key) ||
      case Traitee.Secrets.CredentialStore.load(:xai, "api_key") do
        {:ok, key} -> key
        :not_found -> nil
      end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tools(map, nil), do: map
  defp maybe_put_tools(map, []), do: map
  defp maybe_put_tools(map, tools), do: Map.put(map, :tools, tools)
end
