defmodule Traitee.Media.TextExtractor do
  @moduledoc "Extract text content from documents."

  @max_chars 50_000

  @spec extract(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract(path) do
    ext = path |> Path.extname() |> String.downcase()

    with {:ok, text} <- extract_by_ext(ext, path) do
      {:ok, truncate(text)}
    end
  end

  defp extract_by_ext(ext, path) when ext in [".txt", ".md", ".log"] do
    File.read(path)
  end

  defp extract_by_ext(".html", path), do: extract_html(path)
  defp extract_by_ext(".htm", path), do: extract_html(path)

  defp extract_by_ext(".json", path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> {:ok, Jason.encode!(decoded, pretty: true)}
          {:error, _} -> {:ok, raw}
        end

      error ->
        error
    end
  end

  defp extract_by_ext(".csv", path), do: extract_csv(path)
  defp extract_by_ext(".xml", path), do: File.read(path)

  defp extract_by_ext(".pdf", _path) do
    {:error, :pdf_extraction_not_available}
  end

  defp extract_by_ext(_ext, path), do: File.read(path)

  defp extract_html(path) do
    case File.read(path) do
      {:ok, html} ->
        text =
          html
          |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
          |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
          |> String.replace(~r/<[^>]+>/, " ")
          |> String.replace(~r/&nbsp;/, " ")
          |> String.replace(~r/&amp;/, "&")
          |> String.replace(~r/&lt;/, "<")
          |> String.replace(~r/&gt;/, ">")
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        {:ok, text}

      error ->
        error
    end
  end

  defp extract_csv(path) do
    case File.read(path) do
      {:ok, raw} ->
        lines = String.split(raw, ~r/\r?\n/, trim: true)

        formatted =
          lines
          |> Enum.take(500)
          |> Enum.map_join("\n", fn line ->
            line
            |> String.split(",")
            |> Enum.map_join(" | ", &String.trim/1)
          end)

        {:ok, formatted}

      error ->
        error
    end
  end

  defp truncate(text) when byte_size(text) > @max_chars do
    String.slice(text, 0, @max_chars) <> "\n... (truncated at #{@max_chars} chars)"
  end

  defp truncate(text), do: text
end
