defmodule Traitee.LLM.Anthropic do
  @moduledoc """
  Anthropic provider -- Claude Opus, Sonnet, Haiku via the Messages API.
  """

  @behaviour Traitee.LLM.Provider

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
    {system, messages} = extract_system(request.messages)
    merged_system = merge_system(system, request.system)
    model_id = resolve_model_id(request.model)
    thinking? = thinking_model?(request.model)

    formatted_messages =
      messages
      |> Enum.map(&format_message/1)
      |> merge_consecutive_roles()

    body =
      %{
        model: model_id,
        messages: formatted_messages,
        max_tokens: request.max_tokens || if(thinking?, do: 8192, else: 4096)
      }
      |> maybe_put(:system, merged_system)
      |> maybe_put_thinking(thinking?)
      |> maybe_put(if(thinking?, do: :__skip__, else: :temperature), request.temperature)
      |> maybe_put_tools(request.tools)

    case post("/messages", body) do
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
    {system, messages} = extract_system(request.messages)
    merged_system = merge_system(system, request.system)
    model_id = resolve_model_id(request.model)
    thinking? = thinking_model?(request.model)

    body =
      %{
        model: model_id,
        messages: Enum.map(messages, &format_message/1),
        max_tokens: request.max_tokens || if(thinking?, do: 8192, else: 4096),
        stream: true
      }
      |> maybe_put(:system, merged_system)
      |> maybe_put_thinking(thinking?)
      |> maybe_put(if(thinking?, do: :__skip__, else: :temperature), request.temperature)

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

  # -- Private --

  defp merge_system(nil, nil), do: nil
  defp merge_system(a, nil), do: a
  defp merge_system(nil, b), do: b
  defp merge_system(a, b), do: a <> "\n\n" <> b

  defp extract_system(messages) do
    {system_msgs, other_msgs} =
      Enum.split_with(messages, &(&1[:role] == "system" or &1.role == "system"))

    system_text =
      case Enum.map(system_msgs, &(&1[:content] || &1.content)) |> Enum.reject(&is_nil/1) do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    {system_text, other_msgs}
  end

  defp resolve_model_id(model_id) do
    case Map.get(@models, model_id) do
      %{id: full_id} -> full_id
      nil -> model_id
    end
  end

  defp format_message(%Traitee.LLM.Types.Message{} = msg) do
    %{role: msg.role, content: msg.content}
  end

  defp format_message(msg) when is_map(msg) do
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

  defp format_tool_result(msg, content) do
    tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]

    %{
      role: "user",
      content: [
        %{type: "tool_result", tool_use_id: tool_call_id, content: to_string(content)}
      ]
    }
  end

  defp format_assistant_with_tools(content, tool_calls) do
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

  defp parse_tool_input(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_tool_input(args) when is_map(args), do: args
  defp parse_tool_input(_), do: %{}

  defp parse_response(%{"content" => content, "usage" => usage} = resp) do
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

  defp thinking_model?(model_id), do: MapSet.member?(@thinking_models, model_id)

  defp maybe_put_thinking(map, false), do: map

  defp maybe_put_thinking(map, true) do
    map
    |> Map.put(:thinking, %{type: "adaptive"})
    |> Map.put(:output_config, %{effort: "medium"})
  end

  defp maybe_put(map, :__skip__, _value), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tools(map, nil), do: map
  defp maybe_put_tools(map, []), do: map

  defp maybe_put_tools(map, tools) do
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

  defp merge_consecutive_roles(messages) do
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

  defp merge_content(a, b) when is_list(a) and is_list(b), do: a ++ b
  defp merge_content(a, b) when is_list(a), do: a ++ [%{type: "text", text: to_string(b)}]
  defp merge_content(a, b) when is_list(b), do: [%{type: "text", text: to_string(a)}] ++ b
  defp merge_content(a, b), do: to_string(a) <> "\n" <> to_string(b)
end
