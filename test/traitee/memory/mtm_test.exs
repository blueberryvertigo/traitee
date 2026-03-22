defmodule Traitee.Memory.MTMTest do
  use Traitee.DataCase, async: false

  alias Traitee.Memory.MTM

  import Traitee.TestHelpers

  describe "store_summary/3" do
    test "inserts a summary record" do
      sid = unique_session_id()
      assert {:ok, summary} = MTM.store_summary(sid, "Users discussed deployment strategies.")
      assert summary.session_id == sid
      assert summary.content == "Users discussed deployment strategies."
      assert summary.message_count == 0
    end

    test "accepts optional attributes" do
      sid = unique_session_id()

      assert {:ok, summary} =
               MTM.store_summary(sid, "Summary text", %{
                 message_count: 20,
                 message_range_start: 1,
                 message_range_end: 20,
                 key_topics: ["elixir", "otp"]
               })

      assert summary.message_count == 20
      assert summary.message_range_start == 1
      assert summary.message_range_end == 20
      assert summary.key_topics == ["elixir", "otp"]
    end
  end

  describe "get_summaries/1" do
    test "returns summaries ordered by creation time" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "First summary")
      {:ok, _} = MTM.store_summary(sid, "Second summary")
      {:ok, _} = MTM.store_summary(sid, "Third summary")

      summaries = MTM.get_summaries(sid)
      assert length(summaries) == 3

      assert Enum.map(summaries, & &1.content) == [
               "First summary",
               "Second summary",
               "Third summary"
             ]
    end

    test "returns empty list for unknown session" do
      assert MTM.get_summaries("nonexistent_session") == []
    end

    test "sessions are isolated" do
      sid1 = unique_session_id()
      sid2 = unique_session_id()
      {:ok, _} = MTM.store_summary(sid1, "Session 1 summary")
      {:ok, _} = MTM.store_summary(sid2, "Session 2 summary")

      assert length(MTM.get_summaries(sid1)) == 1
      assert length(MTM.get_summaries(sid2)) == 1
    end
  end

  describe "get_recent/2" do
    test "returns last N summaries" do
      sid = unique_session_id()
      for i <- 1..5, do: MTM.store_summary(sid, "Summary #{i}")

      recent = MTM.get_recent(sid, 2)
      assert length(recent) == 2

      all = MTM.get_summaries(sid)
      assert length(all) == 5
    end

    test "returns all if fewer than N exist" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "Only one")

      recent = MTM.get_recent(sid, 10)
      assert length(recent) == 1
    end
  end

  describe "count/1" do
    test "returns the number of summaries" do
      sid = unique_session_id()
      assert MTM.count(sid) == 0

      {:ok, _} = MTM.store_summary(sid, "One")
      assert MTM.count(sid) == 1

      {:ok, _} = MTM.store_summary(sid, "Two")
      assert MTM.count(sid) == 2
    end
  end

  describe "search/2" do
    test "finds summaries by keyword" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "Discussed Elixir deployment on AWS")
      {:ok, _} = MTM.store_summary(sid, "Talked about Rust performance")

      results = MTM.search(sid, "Elixir")
      assert length(results) == 1
      assert hd(results).content =~ "Elixir"
    end

    test "returns empty for no match" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "Nothing relevant here")

      assert MTM.search(sid, "quantum_physics") == []
    end

    test "is scoped to session" do
      sid1 = unique_session_id()
      sid2 = unique_session_id()
      {:ok, _} = MTM.store_summary(sid1, "Elixir patterns")
      {:ok, _} = MTM.store_summary(sid2, "Elixir concurrency")

      assert length(MTM.search(sid1, "Elixir")) == 1
    end
  end

  describe "get_with_embeddings/1" do
    test "returns only summaries with embeddings" do
      sid = unique_session_id()
      {:ok, _} = MTM.store_summary(sid, "No embedding")

      {:ok, _} =
        MTM.store_summary(sid, "Has embedding", %{
          message_count: 5,
          embedding: :erlang.term_to_binary([0.1, 0.2, 0.3])
        })

      with_emb = MTM.get_with_embeddings(sid)
      assert length(with_emb) == 1
      assert hd(with_emb).content == "Has embedding"
    end
  end

  describe "summarization_prompt/1" do
    test "formats messages into a prompt" do
      messages = [
        %{role: "user", content: "What is OTP?"},
        %{role: "assistant", content: "OTP stands for Open Telecom Platform."}
      ]

      prompt = MTM.summarization_prompt(messages)
      assert is_binary(prompt)
      assert prompt =~ "user: What is OTP?"
      assert prompt =~ "assistant: OTP stands for"
      assert prompt =~ "JSON"
      assert prompt =~ "summary"
      assert prompt =~ "entities"
    end

    test "handles empty message list" do
      prompt = MTM.summarization_prompt([])
      assert is_binary(prompt)
      assert prompt =~ "summary"
    end
  end
end
