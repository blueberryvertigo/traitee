defmodule Traitee.LLM.SSETest do
  use ExUnit.Case, async: true

  alias Traitee.LLM.SSE

  describe "extract_lines/1" do
    test "keeps the trailing partial line as carry-over" do
      assert SSE.extract_lines("data: a\ndata: b") == {["data: a"], "data: b"}
    end

    test "returns empty carry-over when buffer ends with a newline" do
      assert SSE.extract_lines("complete\n") == {["complete"], ""}
    end

    test "returns no complete lines for a partial buffer" do
      assert SSE.extract_lines("partial") == {[], "partial"}
    end

    test "handles empty buffer" do
      assert SSE.extract_lines("") == {[], ""}
    end

    test "strips carriage returns from CRLF streams" do
      assert SSE.extract_lines("line\r\npartial") == {["line"], "partial"}
    end

    test "reassembles a line split across chunks" do
      {lines1, rest1} = SSE.extract_lines(~s|data: {"a":|)
      assert lines1 == []

      {lines2, rest2} = SSE.extract_lines(rest1 <> ~s| 1}\ndata: next|)
      assert lines2 == [~s|data: {"a": 1}|]
      assert rest2 == "data: next"
    end
  end
end
