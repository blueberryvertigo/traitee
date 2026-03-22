defmodule Traitee.LLM.OpenAI do
  @moduledoc """
  OpenAI provider -- GPT-4o, GPT-4.1, o3/o4-mini via the Chat Completions API.
  """

  @behaviour Traitee.LLM.Provider

  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, ModelInfo}

  @api_base "https://api.openai.com/v1"

  @models %{
    "gpt-4o" => %ModelInfo{
      id: "gpt-4o",
      provider: :openai,
      context_window: 128_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.0025,
      cost_per_1k_output: 0.01,
      supports_tools: true,
      supports_vision: true
    },
    "gpt-4o-mini" => %ModelInfo{
      id: "gpt-4o-mini",
      provider: :openai,
      context_window: 128_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.00015,
      cost_per_1k_output: 0.0006,
      supports_tools: true,
      supports_vision: true
    },
    "gpt-4.1" => %ModelInfo{
      id: "gpt-4.1",
      provider: :openai,
      context_window: 1_000_000,
      max_output_tokens: 32_768,
      cost_per_1k_input: 0.002,
      cost_per_1k_output: 0.008,
      supports_tools: true,
      supports_vision: true
    },
    "o3-mini" => %ModelInfo{
      id: "o3-mini",
      provider: :openai,
      context_window: 200_000,
      max_output_tokens: 100_000,
      cost_per_1k_input: 0.0011,
      cost_per_1k_output: 0.0044,
      supports_tools: true,
      supports_vision: false
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
  def embed(texts) when is_list(texts) do
    body = %{
      model: "text-embedding-3-small",
      input: texts
    }

    case post("/embeddings", body) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        embeddings = Enum.map(data, & &1["embedding"])
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def model_info(model_id) do
    Map.get(@models, model_id, %ModelInfo{
      id: model_id,
      provider: :openai,
      context_window: 128_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.002,
      cost_per_1k_output: 0.008,
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
    Application.get_env(:traitee, :openai_api_key) ||
      case Traitee.Secrets.CredentialStore.load(:openai, "api_key") do
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
