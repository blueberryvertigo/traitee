defmodule Traitee.Channels.Splitter do
  @moduledoc """
  Splits long outbound messages into parts that fit a channel's size limit.

  Split points prefer paragraph breaks, then single newlines, then word
  boundaries, hard-splitting only as a last resort.
  """

  @separators ["\n\n", "\n", " "]

  @doc """
  Splits `text` into a list of parts, each at most `limit` characters long.

  Returns the text as a single-element list when it already fits.
  """
  def split_message(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if String.length(text) <= limit do
      [text]
    else
      do_split(text, limit)
    end
  end

  defp do_split("", _limit), do: []

  defp do_split(text, limit) do
    if String.length(text) <= limit do
      [text]
    else
      {part, rest} = split_chunk(text, limit)

      case String.trim_trailing(part) do
        "" -> do_split(rest, limit)
        trimmed -> [trimmed | do_split(rest, limit)]
      end
    end
  end

  defp split_chunk(text, limit) do
    # Window includes one extra char so a boundary sitting exactly at `limit` is found.
    window = String.slice(text, 0, limit + 1)

    case find_break(window, limit) do
      nil ->
        {String.slice(text, 0, limit), String.slice(text, limit..-1//1)}

      {idx, sep_length} ->
        rest = text |> String.slice((idx + sep_length)..-1//1) |> String.trim_leading()
        {String.slice(text, 0, idx), rest}
    end
  end

  defp find_break(window, limit) do
    Enum.find_value(@separators, fn sep ->
      case last_separator(window, sep, limit) do
        nil -> nil
        idx -> {idx, String.length(sep)}
      end
    end)
  end

  # Character index where the last occurrence of `sep` starts, or nil when absent.
  defp last_separator(window, sep, limit) do
    case String.split(window, sep) do
      [_no_match] ->
        nil

      parts ->
        tail_length = parts |> List.last() |> String.length()
        idx = String.length(window) - tail_length - String.length(sep)
        if idx > 0 and idx <= limit, do: idx, else: nil
    end
  end
end
