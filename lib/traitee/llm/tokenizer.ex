defmodule Traitee.LLM.Tokenizer do
  @moduledoc """
  Token counting for budget management.

  Uses a fast approximation based on byte-pair encoding heuristics.
  For OpenAI models, ~4 characters per token is a reasonable estimate.
  For Anthropic models, similar ratios apply.

  A Rustler NIF wrapping tiktoken-rs can replace this for exact counts.
  """

  alias Traitee.LLM.Provider

  @chars_per_token 4.0
  @overhead_per_message 4

  @doc """
  Estimates token count for a string.

  Per-message overhead is applied only by `count_messages/1`.
  """
  def count_tokens(text) when is_binary(text) do
    ceil(String.length(text) / @chars_per_token)
  end

  def count_tokens(nil), do: 0

  @doc """
  Estimates token count for a list of messages.
  Each message has overhead for role/formatting.
  """
  def count_messages(messages) when is_list(messages) do
    base = 3

    messages
    |> Enum.reduce(base, fn msg, acc ->
      content = extract_content(msg)
      acc + count_tokens(content) + @overhead_per_message
    end)
  end

  @doc """
  Estimates token count for a tool definition (JSON schema).
  """
  def count_tool(tool) when is_map(tool) do
    tool
    |> Jason.encode!()
    |> count_tokens()
  end

  @doc """
  Returns the context window size for a given model string.
  """
  def context_window(model_string) do
    case Provider.parse_model(model_string) do
      {:ok, {module, model_id}} ->
        info = module.model_info(model_id)
        info.context_window

      {:error, _} ->
        128_000
    end
  end

  @doc """
  Returns the max output tokens for a given model string.
  """
  def max_output(model_string) do
    case Provider.parse_model(model_string) do
      {:ok, {module, model_id}} ->
        info = module.model_info(model_id)
        info.max_output_tokens

      {:error, _} ->
        4_096
    end
  end

  defp extract_content(msg) when is_map(msg) do
    content = Map.get(msg, :content) || Map.get(msg, "content")
    tool_calls = Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls")
    serialize_content(content, tool_calls)
  end

  defp extract_content(_), do: ""

  defp serialize_content(content, tool_calls) when is_list(tool_calls) and tool_calls != [] do
    to_text(content) <> Jason.encode!(tool_calls)
  end

  defp serialize_content(content, _tool_calls), do: to_text(content)

  defp to_text(nil), do: ""
  defp to_text(content) when is_binary(content), do: content
  defp to_text(content), do: Jason.encode!(content)
end
