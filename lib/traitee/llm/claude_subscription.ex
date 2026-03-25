defmodule Traitee.LLM.ClaudeSubscription do
  @moduledoc """
  Claude subscription provider -- uses a Claude Pro/Max setup-token to call
  the Anthropic Messages API at zero per-token cost.

  Authenticates with a Bearer token (from `claude setup-token`) instead of an
  API key. Requires specific headers and a system prompt prefix that Anthropic
  validates for subscription-based access.

  ## Setup

      # 1. Generate a setup token in another terminal:
      claude setup-token

      # 2. Paste it into Traitee:
      mix traitee.oauth

      # 3. Configure your model in TOML:
      [agent]
      model = "sub/claude-sonnet-4"
  """

  @behaviour Traitee.LLM.Provider

  require Logger

  alias Traitee.LLM.AnthropicShared
  alias Traitee.LLM.OAuth.TokenManager
  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, ModelInfo}

  @api_base "https://api.anthropic.com/v1"
  @api_version "2023-06-01"

  @required_prefix "You are Claude Code, Anthropic's official CLI for Claude."

  @beta_headers "oauth-2025-04-20,interleaved-thinking-2025-05-14"

  @thinking_models MapSet.new(["claude-opus-4.6", "claude-sonnet-4.6"])

  @models %{
    "claude-opus-4.6" => %ModelInfo{
      id: "claude-opus-4-6",
      provider: :claude_subscription,
      context_window: 200_000,
      max_output_tokens: 16_000,
      cost_per_1k_input: 0.0,
      cost_per_1k_output: 0.0,
      supports_tools: true,
      supports_vision: true
    },
    "claude-sonnet-4" => %ModelInfo{
      id: "claude-sonnet-4-20250514",
      provider: :claude_subscription,
      context_window: 200_000,
      max_output_tokens: 16_384,
      cost_per_1k_input: 0.0,
      cost_per_1k_output: 0.0,
      supports_tools: true,
      supports_vision: true
    },
    "claude-opus-4" => %ModelInfo{
      id: "claude-opus-4-20250514",
      provider: :claude_subscription,
      context_window: 200_000,
      max_output_tokens: 32_000,
      cost_per_1k_input: 0.0,
      cost_per_1k_output: 0.0,
      supports_tools: true,
      supports_vision: true
    },
    "claude-haiku-3.5" => %ModelInfo{
      id: "claude-3-5-haiku-20241022",
      provider: :claude_subscription,
      context_window: 200_000,
      max_output_tokens: 8_192,
      cost_per_1k_input: 0.0,
      cost_per_1k_output: 0.0,
      supports_tools: true,
      supports_vision: true
    }
  }

  @impl true
  def configured? do
    TokenManager.authenticated?()
  end

  @impl true
  def complete(%CompletionRequest{} = request) do
    with {:ok, token} <- TokenManager.get_access_token() do
      case do_complete(request, token) do
        {:ok, %{status: 401}} ->
          retry_after_refresh(request)

        {:ok, %{status: 200, body: resp}} ->
          {:ok, AnthropicShared.parse_response(resp)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @impl true
  def stream(%CompletionRequest{} = request, callback) when is_function(callback, 1) do
    with {:ok, token} <- TokenManager.get_access_token() do
      {system, messages} = AnthropicShared.extract_system(request.messages)
      merged_system = AnthropicShared.merge_system(system, request.system)
      final_system = prepend_required_prefix(merged_system)
      model_id = AnthropicShared.resolve_model_id(request.model, @models)
      thinking? = AnthropicShared.thinking_model?(request.model, @thinking_models)

      body =
        %{
          model: model_id,
          messages: Enum.map(messages, &AnthropicShared.format_message/1),
          max_tokens: request.max_tokens || if(thinking?, do: 8192, else: 4096),
          stream: true
        }
        |> AnthropicShared.maybe_put(:system, final_system)
        |> AnthropicShared.maybe_put_thinking(thinking?)
        |> AnthropicShared.maybe_put(
          if(thinking?, do: :__skip__, else: :temperature),
          request.temperature
        )

      req =
        build_req(token)
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
  end

  @impl true
  def embed(_texts) do
    {:error, :not_supported}
  end

  @impl true
  def model_info(model_id) do
    Map.get(@models, model_id, %ModelInfo{
      id: model_id,
      provider: :claude_subscription,
      context_window: 200_000,
      max_output_tokens: 8_192,
      cost_per_1k_input: 0.0,
      cost_per_1k_output: 0.0,
      supports_tools: true,
      supports_vision: true
    })
  end

  # -- Private --

  defp do_complete(request, token) do
    {system, messages} = AnthropicShared.extract_system(request.messages)
    merged_system = AnthropicShared.merge_system(system, request.system)
    final_system = prepend_required_prefix(merged_system)
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
      |> AnthropicShared.maybe_put(:system, final_system)
      |> AnthropicShared.maybe_put_thinking(thinking?)
      |> AnthropicShared.maybe_put(
        if(thinking?, do: :__skip__, else: :temperature),
        request.temperature
      )
      |> AnthropicShared.maybe_put_tools(request.tools)

    build_req(token)
    |> Req.post(url: "#{@api_base}/messages", json: body)
  end

  defp retry_after_refresh(request) do
    Logger.warning("[claude_subscription] Got 401, attempting token refresh")

    case TokenManager.refresh() do
      :ok ->
        case TokenManager.get_access_token() do
          {:ok, new_token} ->
            case do_complete(request, new_token) do
              {:ok, %{status: 200, body: resp}} ->
                {:ok, AnthropicShared.parse_response(resp)}

              {:ok, %{status: status, body: body}} ->
                {:error, {:api_error, status, body}}

              {:error, reason} ->
                {:error, {:request_failed, reason}}
            end

          error ->
            error
        end

      {:error, reason} ->
        {:error,
         {:auth_expired,
          "Token refresh failed: #{inspect(reason)}. Run `mix traitee.oauth` to re-authenticate."}}
    end
  end

  defp build_req(access_token) do
    Req.new(
      headers: [
        {"authorization", "Bearer #{access_token}"},
        {"anthropic-version", @api_version},
        {"anthropic-beta", @beta_headers},
        {"content-type", "application/json"},
        {"user-agent", "claude-code/1.0"}
      ],
      receive_timeout: 120_000,
      retry: false
    )
  end

  # The API validates that the first system block is exactly the Claude Code prefix.
  # System must be an array of text blocks, not a concatenated string.
  defp prepend_required_prefix(nil) do
    [%{type: "text", text: @required_prefix}]
  end

  defp prepend_required_prefix("") do
    [%{type: "text", text: @required_prefix}]
  end

  defp prepend_required_prefix(system) do
    [
      %{type: "text", text: @required_prefix},
      %{type: "text", text: system}
    ]
  end
end
