defmodule Traitee.Memory.QueryExpansion do
  @moduledoc "Query expansion for improved memory recall."

  @max_queries 5

  @stop_words ~w(a an the is are was were be been being have has had do does did
    will would shall should may might must can could of in to for on with at by
    from as into through during before after above below between out off over
    under again further then once here there when where why how all both each
    few more most other some such no nor not only own same so than too very
    just don doesn didn won wouldn i me my myself we our ours ourselves you your
    yours yourself yourselves he him his himself she her hers herself it its
    itself they them their theirs themselves what which who whom this that these
    those am about up if or because until while)

  @doc """
  Expands a user message into multiple search queries for better recall.
  Returns a deduplicated list of up to #{@max_queries} query strings.
  """
  def expand(message) when is_binary(message) do
    [
      message,
      extract_noun_phrases(message),
      extract_keywords(message),
      extract_question_subject(message)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
    |> Enum.take(@max_queries)
  end

  defp extract_noun_phrases(text) do
    phrases =
      Regex.scan(~r/"([^"]+)"/, text)
      |> Enum.map(fn [_, captured] -> captured end)

    capitalized =
      Regex.scan(~r/\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)/, text)
      |> Enum.map(fn [match | _] -> match end)
      |> Enum.reject(&(String.length(&1) < 3))

    case phrases ++ capitalized do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp extract_keywords(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(&1 in @stop_words))
      |> Enum.reject(&(String.length(&1) < 3))

    case words do
      [] -> nil
      kw -> Enum.join(kw, " ")
    end
  end

  defp extract_question_subject(text) do
    cond do
      match = Regex.run(~r/(?:what|who|where|when) (?:is|are|was|were) (.+?)[\?\.]*$/i, text) ->
        Enum.at(match, 1)

      match = Regex.run(~r/(?:tell me about|explain|describe|what about) (.+?)[\?\.]*$/i, text) ->
        Enum.at(match, 1)

      match = Regex.run(~r/(?:how (?:do|does|did|can|to)) (.+?)[\?\.]*$/i, text) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end
end
