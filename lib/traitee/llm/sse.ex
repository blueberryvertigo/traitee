defmodule Traitee.LLM.SSE do
  @moduledoc """
  Buffered line extraction for streaming LLM responses (SSE and NDJSON).

  Raw transport chunks can end mid-line, so streaming parsers keep the
  trailing partial line as a carry-over buffer and prepend it to the next
  chunk, parsing only complete lines.
  """

  @doc """
  Splits `buffer` into complete lines and the trailing partial line.

  Trailing carriage returns are stripped from complete lines so CRLF
  streams parse the same as LF streams.
  """
  def extract_lines(buffer) when is_binary(buffer) do
    lines = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(lines, -1)
    {Enum.map(complete, &String.trim_trailing(&1, "\r")), rest}
  end
end
