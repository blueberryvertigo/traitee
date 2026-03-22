defmodule Traitee.TestHelpers do
  @moduledoc "Shared helpers for tests across all domains."

  @doc "Generate a unique session ID for test isolation."
  def unique_session_id do
    "test_session_#{:erlang.unique_integer([:positive])}"
  end

  @doc "Create a temporary directory that is cleaned up after the test."
  def tmp_dir!(prefix \\ "traitee_test") do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  @doc "Builds a sample inbound message map."
  def build_inbound(text, opts \\ []) do
    %{
      text: text,
      sender_id: opts[:sender_id] || "user_#{:erlang.unique_integer([:positive])}",
      sender_name: opts[:sender_name] || "Test User",
      channel_type: opts[:channel_type] || :cli,
      channel_id: opts[:channel_id],
      reply_to: opts[:reply_to],
      metadata: opts[:metadata] || %{}
    }
  end

  @doc "Creates a fake embedding vector of given dimension."
  def fake_embedding(dim \\ 384) do
    for _ <- 1..dim, do: :rand.uniform() - 0.5
  end

  @doc "Normalizes a vector to unit length."
  def normalize_embedding(vec) do
    norm = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    if norm == 0.0, do: vec, else: Enum.map(vec, &(&1 / norm))
  end

  @doc "Builds an STM state with a fresh ETS table for isolated testing."
  def init_test_stm(session_id, opts \\ []) do
    table = :"traitee_stm_test_#{session_id}"

    if :ets.whereis(table) != :undefined do
      :ets.delete(table)
    end

    :ets.new(table, [:ordered_set, :named_table, :public, read_concurrency: true])
    capacity = opts[:capacity] || 50
    %{table: table, session_id: session_id, capacity: capacity, counter: 0}
  end

  @doc "Cleans up a test STM ETS table."
  def cleanup_test_stm(stm_state) do
    if :ets.whereis(stm_state.table) != :undefined do
      :ets.delete(stm_state.table)
    end
  end
end
