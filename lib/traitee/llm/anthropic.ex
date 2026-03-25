defmodule Traitee.LLM.Anthropic do
  @moduledoc """
  Anthropic provider -- Claude Opus, Sonnet, Haiku via the Messages API.
  Authenticates with an API key (`x-api-key` header).
  """

  @behaviour Traitee.LLM.Provider

  alias Traitee.LLM.AnthropicShared
  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, ModelInfo}

  @api_base "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @thinking_models MapSet.new(["claude-opus-4.6", "claude-sonnet-4.6"])

  @models %{
    "claude-opus-4.6" => %ModelInfo{
      id: "claude-opus-4-6",
      provider: :anthropic,
      context_window: 200_000,
      max_output_tokens: 16_000,
      cost_per_1k_input: 0.005,
      cost_per_1k_output: 0.025,
      supports_tools: true,
      supports_vision: true
    },
    "claude-sonnet-4" => %ModelInfo{
      id: "claude-sonnet-4-20250514",
      provider: :anthropic,
      context_window: 200_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.003,
      cost_per_1k_output: 0.015,
      supports_tools: true,
      supports_vision: true
    },
    "claude-opus-4" => %ModelInfo{
      id: "claude-opus-4-20250514",
      provider: :anthropic,
      context_window: 200_000,
      max_output_tokens: 32_000,
      cost_per_1k_input: 0.015,
      cost_per_1k_output: 0.075,
      supports_tools: true,
      supports_vision: true
    },
    "claude-haiku-3.5" => %ModelInfo{
      id: "claude-3-5-haiku-20241022",
      provider: :anthropic,
      context_window: 200_000,
      max_output_tokens: 8_192,
      cost_per_1k_input: 0.0008,
      cost_per_1k_output: 0.004,
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
    {system, messages} = AnthropicShared.extract_system(request.messages)
    merged_system = AnthropicShared.merge_system(system, request.system)
    model_id = AnthropicShared.resolve_model_id(request.model, @models)
    thinking? = AnthropicShared.thinking_model?(request.model, @thinking_models)

    formatted_messages =
      messages
      |> Enum.map(&AnthropicShared.format_message/1)
      |> AnthropicShared.merge_consecutive_roles()

    body =
      %{
        model: model_id,
        messages: formatted_messages,
        max_tokens: request.max_tokens || if(thinking?, do: 8192, else: 4096)
      }
      |> AnthropicShared.maybe_put(:system, merged_system)
      |> AnthropicShared.maybe_put_thinking(thinking?)
      |> AnthropicShared.maybe_put(
        if(thinking?, do: :__skip__, else: :temperature),
        request.temperature
      )
      |> AnthropicShared.maybe_put_tools(request.tools)

    case post("/messages", body) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, AnthropicShared.parse_response(resp)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def stream(%CompletionRequest{} = request, callback) when is_function(callback, 1) do
    {system, messages} = AnthropicShared.extract_system(request.messages)
    merged_system = AnthropicShared.merge_system(system, request.system)
    model_id = AnthropicShared.resolve_model_id(request.model, @models)
    thinking? = AnthropicShared.thinking_model?(request.model, @thinking_models)

    body =
      %{
        model: model_id,
        messages: Enum.map(messages, &AnthropicShared.format_message/1),
        max_tokens: request.max_tokens || if(thinking?, do: 8192, else: 4096),
        stream: true
      }
      |> AnthropicShared.maybe_put(:system, merged_system)
      |> AnthropicShared.maybe_put_thinking(thinking?)
      |> AnthropicShared.maybe_put(
        if(thinking?, do: :__skip__, else: :temperature),
        request.temperature
      )

    req =
      build_req()
      |> Req.merge(
        url: "#{@api_base}/messages",
        json: body,
        into: fn {:data, data}, acc ->
          for line <- String.split(data, "\n", trim: true) do
            case line do
              "data: " <> json ->
                case Jason.decode(json) do
                  {:ok,
                   %{
                     "type" => "content_block_delta",
                     "delta" => %{"type" => "text_delta", "text" => text}
                   }} ->
                    callback.(text)

                  {:ok,
                   %{"type" => "content_block_delta", "delta" => %{"type" => "thinking_delta"}}} ->
                    :ok

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
      provider: :anthropic,
      context_window: 200_000,
      max_output_tokens: 8_192,
      cost_per_1k_input: 0.003,
      cost_per_1k_output: 0.015,
      supports_tools: true,
      supports_vision: true
    })
  end

  # -- Private (auth & transport) --

  defp post(path, body) do
    build_req()
    |> Req.post(url: "#{@api_base}#{path}", json: body)
  end

  defp build_req do
    Req.new(
      headers: [
        {"x-api-key", api_key()},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ],
      receive_timeout: 120_000,
      retry: false
    )
  end

  defp api_key do
    Application.get_env(:traitee, :anthropic_api_key) ||
      case Traitee.Secrets.CredentialStore.load(:anthropic, "api_key") do
        {:ok, key} -> key
        :not_found -> nil
      end
  end
end
