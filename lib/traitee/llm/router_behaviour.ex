defmodule Traitee.LLM.RouterBehaviour do
  @moduledoc "Behaviour for LLM Router, enabling Mox-based testing."

  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse}

  @callback complete(request :: CompletionRequest.t()) ::
              {:ok, CompletionResponse.t()} | {:error, term()}
  @callback complete_with_tools(request :: CompletionRequest.t(), tools :: [map()]) ::
              {:ok, CompletionResponse.t()} | {:error, term()}
  @callback stream(request :: CompletionRequest.t(), callback :: (String.t() -> any())) ::
              {:ok, CompletionResponse.t()} | {:error, term()}
  @callback embed(texts :: [String.t()]) ::
              {:ok, [[float()]]} | {:error, term()}
  @callback usage_stats() :: map()
  @callback model_info() :: map()
end
