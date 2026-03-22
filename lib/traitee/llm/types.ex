defmodule Traitee.LLM.Types do
  @moduledoc """
  Shared types for LLM provider interactions.
  """

  defmodule Message do
    @moduledoc "A single message in a conversation."
    defstruct [:role, :content, :tool_calls, :tool_call_id, :name]

    @type t :: %__MODULE__{
            role: String.t(),
            content: String.t() | nil,
            tool_calls: [map()] | nil,
            tool_call_id: String.t() | nil,
            name: String.t() | nil
          }
  end

  defmodule CompletionRequest do
    @moduledoc "Request to an LLM provider."
    defstruct [
      :model,
      :messages,
      :tools,
      :temperature,
      :max_tokens,
      :stream,
      :system
    ]

    @type t :: %__MODULE__{
            model: String.t(),
            messages: [Message.t()],
            tools: [map()] | nil,
            temperature: float() | nil,
            max_tokens: integer() | nil,
            stream: boolean(),
            system: String.t() | nil
          }
  end

  defmodule CompletionResponse do
    @moduledoc "Response from an LLM provider."
    defstruct [
      :content,
      :tool_calls,
      :model,
      :usage,
      :finish_reason
    ]

    @type t :: %__MODULE__{
            content: String.t() | nil,
            tool_calls: [map()] | nil,
            model: String.t(),
            usage: usage(),
            finish_reason: String.t() | nil
          }

    @type usage :: %{
            prompt_tokens: integer(),
            completion_tokens: integer(),
            total_tokens: integer()
          }
  end

  defmodule ModelInfo do
    @moduledoc "Metadata about a model."
    defstruct [
      :id,
      :provider,
      :context_window,
      :max_output_tokens,
      :cost_per_1k_input,
      :cost_per_1k_output,
      :supports_tools,
      :supports_vision
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            provider: atom(),
            context_window: integer(),
            max_output_tokens: integer(),
            cost_per_1k_input: float(),
            cost_per_1k_output: float(),
            supports_tools: boolean(),
            supports_vision: boolean()
          }
  end
end
