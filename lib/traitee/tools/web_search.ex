defmodule Traitee.Tools.WebSearch do
  @moduledoc """
  Web search tool. Queries a search API and returns results.
  Supports SearXNG (self-hosted) or can be extended with other providers.
  """

  @behaviour Traitee.Tools.Tool

  @impl true
  def name, do: "web_search"

  @impl true
  def description do
    "Search the web for current information. Returns titles, URLs, and snippets."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The search query"
        },
        "num_results" => %{
          "type" => "integer",
          "description" => "Number of results to return (default 5)",
          "default" => 5
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query} = args) do
    num = args["num_results"] || 5
    config = Traitee.Config.get([:tools, :web_search]) || %{}

    case config[:provider] do
      "searxng" -> search_searxng(query, num, config)
      _ -> {:error, "No search provider configured. Set tools.web_search.provider in config."}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: query"}

  defp search_searxng(query, num, config) do
    base_url = config[:url] || "http://localhost:8080"
    url = "#{base_url}/search"

    case Req.get(url,
           params: [q: query, format: "json", categories: "general"],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"results" => results}}} ->
        formatted =
          results
          |> Enum.take(num)
          |> Enum.map_join("\n\n---\n\n", fn r ->
            title = r["title"] || ""
            url = r["url"] || ""
            snippet = r["content"] || ""
            "#{title}\n#{url}\n#{snippet}"
          end)

        {:ok, formatted}

      {:ok, %{status: status}} ->
        {:error, "Search failed with status #{status}"}

      {:error, reason} ->
        {:error, "Search request failed: #{inspect(reason)}"}
    end
  end
end
