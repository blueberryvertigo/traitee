defmodule Traitee.LLM.AnthropicShared do
  @moduledoc """
  Shared message formatting, response parsing, and request body helpers
  for the Anthropic Messages API. Used by both `Anthropic` (API key) and
  `ClaudeSubscription` (setup-token) providers.
  """

  alias Traitee.LLM.Types.CompletionResponse

  # -- System prompt helpers --

  def merge_system(nil, nil), do: nil
  def merge_system(a, nil), do: a
  def merge_system(nil, b), do: b
  def merge_system(a, b), do: a <> "\n\n" <> b

  def extract_system(messages) do
    {system_msgs, other_msgs} =
      Enum.split_with(messages, &(&1[:role] == "system" or &1.role == "system"))

    system_text =
      case Enum.map(system_msgs, &(&1[:content] || &1.content)) |> Enum.reject(&is_nil/1) do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    {system_text, other_msgs}
  end

  # -- Model helpers --

  def resolve_model_id(model_id, models) do
    case Map.get(models, model_id) do
      %{id: full_id} -> full_id
      nil -> model_id
    end
  end

  def thinking_model?(model_id, thinking_models) do
    MapSet.member?(thinking_models, model_id)
  end

  # -- Message formatting --

  def format_message(%Traitee.LLM.Types.Message{} = msg) do
    %{role: msg.role, content: msg.content}
  end

  def format_message(msg) when is_map(msg) do
    role = msg[:role] || msg["role"]
    content = msg[:content] || msg["content"]
    tool_calls = msg[:tool_calls] || msg["tool_calls"]

    cond do
      role == "tool" ->
        format_tool_result(msg, content)

      role == "assistant" && is_list(tool_calls) && tool_calls != [] ->
        format_assistant_with_tools(content, tool_calls)

      true ->
        %{role: role, content: content}
    end
  end

  def format_tool_result(msg, content) do
    tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]

    %{
      role: "user",
      content: [
        %{type: "tool_result", tool_use_id: tool_call_id, content: to_string(content)}
      ]
    }
  end

  def format_assistant_with_tools(content, tool_calls) do
    blocks = if content && content != "", do: [%{type: "text", text: content}], else: []

    tool_blocks =
      Enum.map(tool_calls, fn call ->
        func = call["function"] || call[:function] || %{}
        input = parse_tool_input(func["arguments"] || func[:arguments])

        %{
          type: "tool_use",
          id: call["id"] || call[:id],
          name: func["name"] || func[:name],
          input: input
        }
      end)

    %{role: "assistant", content: blocks ++ tool_blocks}
  end

  def parse_tool_input(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  def parse_tool_input(args) when is_map(args), do: args
  def parse_tool_input(_), do: %{}

  # -- Consecutive role merging (Anthropic requires alternating roles) --

  def merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        cond do
          acc == nil ->
            {:cont, msg}

          msg.role == acc.role ->
            merged_content = merge_content(acc.content, msg.content)
            {:cont, %{acc | content: merged_content}}

          true ->
            {:cont, acc, msg}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  def merge_content(a, b) when is_list(a) and is_list(b), do: a ++ b
  def merge_content(a, b) when is_list(a), do: a ++ [%{type: "text", text: to_string(b)}]
  def merge_content(a, b) when is_list(b), do: [%{type: "text", text: to_string(a)}] ++ b
  def merge_content(a, b), do: to_string(a) <> "\n" <> to_string(b)

  # -- Response parsing --

  def parse_response(%{"content" => content, "usage" => usage} = resp) do
    text =
      content
      |> Enum.filter(fn block -> block["type"] == "text" end)
      |> Enum.map_join(fn block -> block["text"] end)

    tool_calls =
      content
      |> Enum.filter(fn block -> block["type"] == "tool_use" end)
      |> case do
        [] ->
          nil

        calls ->
          Enum.map(calls, fn c ->
            %{
              "id" => c["id"],
              "type" => "function",
              "function" => %{"name" => c["name"], "arguments" => Jason.encode!(c["input"])}
            }
          end)
      end

    %CompletionResponse{
      content: text,
      tool_calls: tool_calls,
      model: resp["model"],
      finish_reason: resp["stop_reason"],
      usage: %{
        prompt_tokens: usage["input_tokens"] || 0,
        completion_tokens: usage["output_tokens"] || 0,
        total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
      }
    }
  end

  # -- Request body helpers --

  def maybe_put(map, :__skip__, _value), do: map
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  def maybe_put_tools(map, nil), do: map
  def maybe_put_tools(map, []), do: map

  def maybe_put_tools(map, tools) do
    anthropic_tools =
      Enum.map(tools, fn tool ->
        func = tool["function"] || tool[:function]

        %{
          name: func["name"] || func[:name],
          description: func["description"] || func[:description],
          input_schema: func["parameters"] || func[:parameters]
        }
      end)

    Map.put(map, :tools, anthropic_tools)
  end

  def maybe_put_thinking(map, false), do: map

  def maybe_put_thinking(map, true) do
    map
    |> Map.put(:thinking, %{type: "adaptive"})
    |> Map.put(:output_config, %{effort: "medium"})
  end
end
