defmodule TraiteeWeb.OpenAIProxyController do
  use Phoenix.Controller, formats: [:json]

  @moduledoc "OpenAI-compatible API endpoint so Traitee can be used as an LLM proxy."

  alias Traitee.LLM.Router, as: LLMRouter

  def chat_completions(conn, params) do
    messages =
      (params["messages"] || [])
      |> Enum.map(fn msg ->
        %{role: msg["role"], content: msg["content"]}
      end)

    {system, messages} = extract_system(messages)

    request = %{
      messages: messages,
      temperature: params["temperature"],
      max_tokens: params["max_tokens"],
      tools: params["tools"],
      system: system
    }

    if params["stream"] == true do
      stream_completion(conn, params, request)
    else
      complete_json(conn, params, request)
    end
  end

  def embeddings(conn, params) do
    input = params["input"]
    texts = if is_list(input), do: input, else: [input]

    case LLMRouter.embed(texts) do
      {:ok, vectors} ->
        data =
          vectors
          |> Enum.with_index()
          |> Enum.map(fn {vec, i} ->
            %{object: "embedding", embedding: vec, index: i}
          end)

        json(conn, %{
          object: "list",
          data: data,
          model: params["model"] || "text-embedding-3-small",
          usage: %{prompt_tokens: 0, total_tokens: 0}
        })

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{
          error: %{
            message: "Embedding failed: #{inspect(reason)}",
            type: "upstream_error",
            code: "embedding_error"
          }
        })
    end
  end

  def models(conn, _params) do
    models = [
      %{id: "traitee", object: "model", owned_by: "traitee", created: 0},
      %{id: "traitee-with-memory", object: "model", owned_by: "traitee", created: 0}
    ]

    json(conn, %{object: "list", data: models})
  end

  # -- Private --

  defp complete_json(conn, params, request) do
    case LLMRouter.complete(request) do
      {:ok, resp} ->
        json(conn, %{
          id: "chatcmpl-#{:erlang.unique_integer([:positive])}",
          object: "chat.completion",
          created: System.os_time(:second),
          model: resp.model || params["model"] || "traitee",
          choices: [
            %{
              index: 0,
              message: response_message(resp),
              finish_reason: resp.finish_reason || "stop"
            }
          ],
          usage: format_usage(resp.usage)
        })

      {:error, reason} ->
        llm_error(conn, reason)
    end
  end

  # SSE shim: the upstream call is not streamed; the full completion is sent
  # as a single `data:` chunk followed by `data: [DONE]` so OpenAI streaming
  # clients terminate correctly instead of hanging on a plain JSON body.
  defp stream_completion(conn, params, request) do
    case LLMRouter.complete(request) do
      {:ok, resp} ->
        send_sse_response(conn, params, resp)

      {:error, reason} ->
        llm_error(conn, reason)
    end
  end

  defp send_sse_response(conn, params, resp) do
    id = "chatcmpl-#{:erlang.unique_integer([:positive])}"
    created = System.os_time(:second)
    model = resp.model || params["model"] || "traitee"

    delta = response_message(resp)
    content_chunk = sse_chunk(id, created, model, delta, nil)
    done_chunk = sse_chunk(id, created, model, %{}, resp.finish_reason || "stop")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce_while([content_chunk, done_chunk, "data: [DONE]\n\n"], conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp sse_chunk(id, created, model, delta, finish_reason) do
    payload = %{
      id: id,
      object: "chat.completion.chunk",
      created: created,
      model: model,
      choices: [%{index: 0, delta: delta, finish_reason: finish_reason}]
    }

    "data: #{Jason.encode!(payload)}\n\n"
  end

  defp response_message(resp) do
    base = %{role: "assistant", content: resp.content}

    case resp.tool_calls do
      calls when is_list(calls) and calls != [] -> Map.put(base, :tool_calls, calls)
      _ -> base
    end
  end

  defp llm_error(conn, reason) do
    conn
    |> put_status(502)
    |> json(%{
      error: %{
        message: "LLM request failed: #{inspect(reason)}",
        type: "upstream_error",
        code: "llm_error"
      }
    })
  end

  # Extracts system messages into request.system and removes them from the
  # message list so providers that take a separate system field (Anthropic)
  # do not receive the prompt twice.
  defp extract_system(messages) do
    {system_msgs, rest} = Enum.split_with(messages, &(&1.role == "system"))

    system =
      case system_msgs |> Enum.map(& &1.content) |> Enum.reject(&is_nil/1) do
        [] -> nil
        parts -> Enum.join(parts, "\n\n")
      end

    {system, rest}
  end

  defp format_usage(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp format_usage(usage) when is_map(usage) do
    pt = Map.get(usage, :prompt_tokens, 0) || 0
    ct = Map.get(usage, :completion_tokens, 0) || 0
    %{prompt_tokens: pt, completion_tokens: ct, total_tokens: pt + ct}
  end
end
