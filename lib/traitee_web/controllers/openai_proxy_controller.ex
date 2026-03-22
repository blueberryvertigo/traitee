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

    request = %{
      messages: messages,
      temperature: params["temperature"],
      max_tokens: params["max_tokens"],
      system: extract_system(messages)
    }

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
              message: %{role: "assistant", content: resp.content},
              finish_reason: resp.finish_reason || "stop"
            }
          ],
          usage: format_usage(resp.usage)
        })

      {:error, reason} ->
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

  defp extract_system(messages) do
    case Enum.find(messages, &(&1.role == "system" || &1[:role] == "system")) do
      %{content: content} -> content
      _ -> nil
    end
  end

  defp format_usage(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp format_usage(usage) when is_map(usage) do
    pt = usage[:prompt_tokens] || Map.get(usage, :prompt_tokens, 0)
    ct = usage[:completion_tokens] || Map.get(usage, :completion_tokens, 0)
    %{prompt_tokens: pt, completion_tokens: ct, total_tokens: pt + ct}
  end
end
