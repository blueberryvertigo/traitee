defmodule Traitee.Security.RateLimiter do
  @moduledoc "Token bucket rate limiter for API and channel requests."

  @table :traitee_rate_limits
  @config_table :traitee_rate_config

  @default_config %{max_tokens: 30, refill_rate: 30, refill_interval_ms: 60_000}

  @spec init() :: :ok
  def init do
    for table <- [@table, @config_table] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:set, :named_table, :public, write_concurrency: true])
      end
    end

    :ok
  end

  @spec check(term(), pos_integer()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check(key, cost \\ 1) do
    init()
    now = System.monotonic_time(:millisecond)
    config = get_config(key)

    case :ets.lookup(@table, key) do
      [{^key, tokens, last_refill}] ->
        elapsed = now - last_refill
        refill_cycles = div(elapsed, config.refill_interval_ms)
        refilled = min(config.max_tokens, tokens + refill_cycles * config.refill_rate)
        new_last = last_refill + refill_cycles * config.refill_interval_ms

        if refilled >= cost do
          :ets.insert(@table, {key, refilled - cost, new_last})
          :ok
        else
          retry_after = config.refill_interval_ms - (now - new_last)
          {:error, :rate_limited, max(retry_after, 0)}
        end

      [] ->
        if config.max_tokens >= cost do
          :ets.insert(@table, {key, config.max_tokens - cost, now})
          :ok
        else
          {:error, :rate_limited, config.refill_interval_ms}
        end
    end
  end

  @spec configure(term(), map()) :: :ok
  def configure(key_prefix, opts) do
    init()
    config = Map.merge(@default_config, opts)
    :ets.insert(@config_table, {key_prefix, config})
    :ok
  end

  defp get_config(key) do
    init()

    case :ets.lookup(@config_table, key) do
      [{^key, config}] ->
        config

      [] ->
        prefix = extract_prefix(key)

        case :ets.lookup(@config_table, prefix) do
          [{^prefix, config}] -> config
          [] -> @default_config
        end
    end
  end

  defp extract_prefix(key) when is_tuple(key), do: elem(key, 0)
  defp extract_prefix(key), do: key
end
