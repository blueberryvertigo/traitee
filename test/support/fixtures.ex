defmodule Traitee.Fixtures do
  @moduledoc "Test data factories for memory, sessions, and LLM types."

  alias Traitee.LLM.Types.{CompletionRequest, CompletionResponse, Message, ModelInfo}

  def completion_request(overrides \\ %{}) do
    Map.merge(
      %CompletionRequest{
        model: "openai/gpt-4o",
        messages: [%Message{role: "user", content: "Hello"}],
        tools: nil,
        temperature: 0.7,
        max_tokens: 4096,
        stream: false,
        system: nil
      },
      overrides
    )
  end

  def completion_response(overrides \\ %{}) do
    Map.merge(
      %CompletionResponse{
        content: "Hello! How can I help you?",
        tool_calls: nil,
        model: "gpt-4o",
        usage: %{prompt_tokens: 10, completion_tokens: 8, total_tokens: 18},
        finish_reason: "stop"
      },
      overrides
    )
  end

  def model_info(overrides \\ %{}) do
    Map.merge(
      %ModelInfo{
        id: "gpt-4o",
        provider: :openai,
        context_window: 128_000,
        max_output_tokens: 16_384,
        cost_per_1k_input: 0.005,
        cost_per_1k_output: 0.015,
        supports_tools: true,
        supports_vision: true
      },
      overrides
    )
  end

  def mmr_candidates(n \\ 5, dim \\ 8) do
    Enum.map(1..n, fn i ->
      embedding = for _ <- 1..dim, do: :rand.uniform() - 0.5

      %{
        source: :summary,
        id: i,
        score: 1.0 - i * 0.1,
        embedding: embedding,
        content: "Candidate #{i} content about topic #{rem(i, 3)}"
      }
    end)
  end

  def cron_job_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "test_job_#{:erlang.unique_integer([:positive])}",
        expression: "0 9 * * 1-5",
        message: "Daily standup reminder",
        enabled: true
      },
      overrides
    )
  end

  def config_map(overrides \\ %{}) do
    Map.merge(
      %{
        agent: %{model: "openai/gpt-4o", fallback_model: "anthropic/claude-sonnet-4"},
        memory: %{stm_capacity: 50, mtm_chunk_size: 20},
        gateway: %{port: 4000, host: "127.0.0.1"},
        channels: %{},
        tools: %{bash: %{enabled: true}, file: %{enabled: true}},
        security: %{enabled: true}
      },
      overrides
    )
  end

  def doctor_results(overrides \\ []) do
    defaults = [
      %{check: :elixir_version, status: :ok, message: "Elixir 1.17.0"},
      %{check: :database, status: :ok, message: "SQLite connected"},
      %{check: :llm_provider, status: :ok, message: "Model: openai/gpt-4o"},
      %{check: :memory_system, status: :ok, message: "3 ETS tables, 100 vectors"},
      %{check: :channels, status: :warning, message: "No channels enabled"},
      %{check: :workspace, status: :ok, message: "Data dir exists"},
      %{check: :disk_space, status: :ok, message: "4200MB free"},
      %{check: :config, status: :ok, message: "Config valid"},
      %{check: :sessions, status: :ok, message: "0 active"},
      %{check: :security, status: :warning, message: "no approved senders"}
    ]

    case overrides do
      [] -> defaults
      overrides -> Keyword.get(overrides, :results, defaults)
    end
  end
end
