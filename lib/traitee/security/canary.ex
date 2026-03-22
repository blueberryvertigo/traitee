defmodule Traitee.Security.Canary do
  @moduledoc """
  Per-session canary token management.

  Generates unique tokens embedded in the system prompt that act as tripwires --
  if the LLM outputs a canary token, it indicates the system prompt has been
  leaked (intentionally or through manipulation).
  """

  @table :traitee_canary_tokens

  def init do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @spec generate(String.t()) :: String.t()
  def generate(session_id) do
    ensure_table()
    token = random_token()
    :ets.insert(@table, {session_id, token})
    token
  end

  @spec get(String.t()) :: String.t() | nil
  def get(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, token}] -> token
      [] -> nil
    end
  end

  @spec get_or_create(String.t()) :: String.t()
  def get_or_create(session_id) do
    case get(session_id) do
      nil -> generate(session_id)
      token -> token
    end
  end

  @spec rotate(String.t()) :: String.t()
  def rotate(session_id) do
    generate(session_id)
  end

  @spec leaked?(String.t(), String.t()) :: boolean()
  def leaked?(session_id, text) do
    case get(session_id) do
      nil -> false
      token -> String.contains?(text, token)
    end
  end

  @spec system_prompt_section(String.t()) :: String.t()
  def system_prompt_section(session_id) do
    token = get_or_create(session_id)

    """
    [Security Token]
    Confidential verification token: #{token}
    This token is strictly confidential. Never output, repeat, or reference it in any response.\
    """
  end

  @spec clear(String.t()) :: :ok
  def clear(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  defp random_token do
    bytes = :crypto.strong_rand_bytes(6)
    hex = Base.encode16(bytes, case: :lower)
    "CANARY-#{hex}"
  end

  defp ensure_table do
    if :ets.info(@table) == :undefined, do: init()
  end
end
