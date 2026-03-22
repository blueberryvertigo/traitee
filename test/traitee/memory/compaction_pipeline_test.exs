defmodule Traitee.Memory.CompactionPipelineTest do
  @moduledoc """
  Integration test for the full STM → Compactor → MTM + LTM pipeline.

  Exercises the real Compactor GenServer with a mocked LLM Router,
  verifying that conversation messages flow through summarization
  and entity extraction into persistent storage.
  """
  use Traitee.DataCase, async: false

  @moduletag :integration

  alias Traitee.Memory.{Compactor, MTM, LTM, STM, Vector}
  alias Traitee.LLM.Types.CompletionResponse

  import Traitee.TestHelpers
  import Mox

  setup :set_mox_global

  setup do
    Vector.init()

    session_id = unique_session_id()

    llm_response =
      Jason.encode!(%{
        "summary" => "Users discussed deploying Elixir services on AWS using Docker containers.",
        "entities" => [
          %{
            "name" => "Elixir",
            "type" => "technology",
            "facts" => ["Elixir is used for backend services", "Elixir compiles to BEAM bytecode"],
            "relations" => [
              %{
                "target" => "AWS",
                "relation_type" => "deployed_on",
                "description" => "Production deployment target"
              }
            ]
          },
          %{
            "name" => "AWS",
            "type" => "platform",
            "facts" => ["AWS hosts the production environment"]
          },
          %{
            "name" => "Docker",
            "type" => "tool",
            "facts" => ["Docker is used for containerization"],
            "relations" => [%{"target" => "AWS", "relation_type" => "runs_on"}]
          }
        ]
      })

    fake_embedding = fake_embedding(384)

    Mox.stub(Traitee.LLM.RouterMock, :complete, fn _request ->
      {:ok,
       %CompletionResponse{
         content: llm_response,
         model: "test-model",
         usage: %{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}
       }}
    end)

    Mox.stub(Traitee.LLM.RouterMock, :embed, fn _texts ->
      {:ok, [fake_embedding]}
    end)

    Application.put_env(:traitee, :compactor_router, Traitee.LLM.RouterMock)

    on_exit(fn ->
      Application.delete_env(:traitee, :compactor_router)
    end)

    %{session_id: session_id, fake_embedding: fake_embedding}
  end

  describe "compaction pipeline" do
    test "flush processes pending messages into MTM summary and LTM entities", %{
      session_id: session_id
    } do
      messages =
        build_conversation([
          {"user", "How should we deploy our Elixir app?"},
          {"assistant", "I'd recommend Docker containers on AWS ECS."},
          {"user", "What about the database?"},
          {"assistant", "RDS PostgreSQL works well with Elixir. You can use Ecto."},
          {"user", "Let's go with that. Can you outline the steps?"},
          {"assistant", "Sure! First, create a Dockerfile with a multi-stage build..."}
        ])

      Compactor.compact(session_id, messages)
      Compactor.flush(session_id)

      wait_for(fn -> MTM.count(session_id) > 0 end)

      summaries = MTM.get_summaries(session_id)
      assert length(summaries) == 1

      summary = hd(summaries)
      assert summary.content =~ "Elixir"
      assert summary.content =~ "AWS"
      assert summary.message_count == 6
      assert "Elixir" in summary.key_topics
      assert summary.embedding != nil

      elixir = LTM.get_entity_by_name("Elixir", "technology")
      assert elixir != nil

      aws = LTM.get_entity_by_name("AWS", "platform")
      assert aws != nil

      docker = LTM.get_entity_by_name("Docker", "tool")
      assert docker != nil

      elixir_facts = LTM.get_facts(elixir.id)
      assert length(elixir_facts) == 2
      fact_contents = Enum.map(elixir_facts, & &1.content)
      assert "Elixir is used for backend services" in fact_contents
      assert "Elixir compiles to BEAM bytecode" in fact_contents

      elixir_rels = LTM.get_relations(elixir.id)

      assert Enum.any?(elixir_rels, fn r ->
               r.direction == :outgoing and r.relation.relation_type == "deployed_on"
             end)

      docker_rels = LTM.get_relations(docker.id)

      assert Enum.any?(docker_rels, fn r ->
               r.direction == :outgoing and r.relation.relation_type == "runs_on"
             end)
    end

    test "STM eviction triggers compaction into MTM and LTM", %{session_id: session_id} do
      capacity = 5
      stm_state = STM.init(session_id, capacity: capacity, rehydrate: false)

      stm_state =
        Enum.reduce(1..(capacity + 3), stm_state, fn i, acc ->
          role = if rem(i, 2) == 1, do: "user", else: "assistant"
          STM.push(acc, role, "Message number #{i}")
        end)

      Compactor.flush(session_id)

      wait_for(fn -> MTM.count(session_id) > 0 end)
      wait_for(fn -> LTM.get_entity_by_name("Elixir", "technology") != nil end)

      assert MTM.count(session_id) >= 1

      summaries = MTM.get_summaries(session_id)
      summary = hd(summaries)
      assert summary.content =~ "Elixir"

      assert LTM.get_entity_by_name("AWS", "platform") != nil

      STM.destroy(stm_state)
    end

    test "multiple flushes produce multiple summaries", %{session_id: session_id} do
      batch_1 =
        build_conversation([
          {"user", "Tell me about Elixir"},
          {"assistant", "Elixir is a functional language on the BEAM VM."}
        ])

      batch_2 =
        build_conversation([
          {"user", "How about deployment?"},
          {"assistant", "Docker on AWS is a great approach."}
        ])

      Compactor.compact(session_id, batch_1)
      Compactor.flush(session_id)
      wait_for(fn -> MTM.count(session_id) >= 1 end)

      Compactor.compact(session_id, batch_2)
      Compactor.flush(session_id)
      wait_for(fn -> MTM.count(session_id) >= 2 end)

      assert MTM.count(session_id) == 2

      summaries = MTM.get_summaries(session_id)
      assert length(summaries) == 2
    end

    test "vector embeddings are stored for semantic retrieval", %{
      session_id: session_id,
      fake_embedding: expected_emb
    } do
      messages =
        build_conversation([
          {"user", "What is GenServer?"},
          {"assistant", "GenServer is an OTP behaviour for stateful processes."}
        ])

      Compactor.compact(session_id, messages)
      Compactor.flush(session_id)

      wait_for(fn -> MTM.count(session_id) > 0 end)

      summary = hd(MTM.get_summaries(session_id))

      Process.sleep(200)

      case Vector.get_embedding(:summary, summary.id) do
        {:ok, stored_emb} ->
          assert length(stored_emb) == 384
          assert_in_delta hd(stored_emb), hd(expected_emb), 0.001

        :not_found ->
          flunk("Expected vector embedding to be stored for summary #{summary.id}")
      end
    end

    test "entity mention counts accumulate across compaction rounds", %{session_id: session_id} do
      for round <- 1..3 do
        messages =
          build_conversation([
            {"user", "Let's talk about Elixir"},
            {"assistant", "Sure, Elixir is great."}
          ])

        Compactor.compact(session_id, messages)
        Compactor.flush(session_id)

        wait_for(fn -> MTM.count(session_id) >= round end)

        wait_for(fn ->
          e = LTM.get_entity_by_name("Elixir", "technology")
          e != nil and e.mention_count >= round
        end)
      end

      elixir = LTM.get_entity_by_name("Elixir", "technology")
      assert elixir != nil
      assert elixir.mention_count >= 3
    end
  end

  # -- Helpers --

  defp build_conversation(pairs) do
    Enum.map(pairs, fn {role, content} ->
      %{role: role, content: content, token_count: ceil(String.length(content) / 4.0) + 4}
    end)
  end

  defp wait_for(fun, timeout \\ 5000, interval \\ 100)

  defp wait_for(_fun, timeout, _interval) when timeout <= 0 do
    flunk("Timed out waiting for async compaction to complete")
  end

  defp wait_for(fun, timeout, interval) do
    if fun.() do
      :ok
    else
      Process.sleep(interval)
      wait_for(fun, timeout - interval, interval)
    end
  end
end
