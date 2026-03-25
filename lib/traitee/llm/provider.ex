defmodule Traitee.LLM.Provider do
  @moduledoc """
  Behaviour for LLM providers. Each provider (OpenAI, Anthropic, Ollama)
  implements these callbacks.
  """

  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, ModelInfo}

  @callback complete(request :: CompletionRequest.t()) ::
              {:ok, CompletionResponse.t()} | {:error, term()}

  @callback stream(request :: CompletionRequest.t(), callback :: (String.t() -> any())) ::
              {:ok, CompletionResponse.t()} | {:error, term()}

  @callback embed(texts :: [String.t()]) ::
              {:ok, [[float()]]} | {:error, term()}

  @callback model_info(model_id :: String.t()) :: ModelInfo.t()

  @callback configured?() :: boolean()

  @doc """
  Parses a model string like "openai/gpt-4o" into {provider_module, model_id}.
  """
  def parse_model(model_string) do
    case String.split(model_string, "/", parts: 2) do
      ["openai", model] -> {:ok, {Traitee.LLM.OpenAI, model}}
      ["anthropic", model] -> {:ok, {Traitee.LLM.Anthropic, model}}
      ["ollama", model] -> {:ok, {Traitee.LLM.Ollama, model}}
      ["xai", model] -> {:ok, {Traitee.LLM.XAI, model}}
      ["sub", model] -> {:ok, {Traitee.LLM.ClaudeSubscription, model}}
      _ -> {:error, {:unknown_provider, model_string}}
    end
  end
end
