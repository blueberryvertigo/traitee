defmodule Traitee.Hooks.Builtin do
  @moduledoc "Built-in hooks for logging, metrics, safety, and cognitive security."

  require Logger

  alias Traitee.Hooks.Engine
  alias Traitee.Security.{Canary, Cognitive, Judge, OutputGuard, Sanitizer, ThreatTracker}

  @spec register_all() :: :ok
  def register_all do
    Engine.register(:before_message, :builtin_log_inbound, &log_inbound/1)
    Engine.register(:before_message, :builtin_rate_check, &check_rate_limit/1)
    Engine.register(:before_message, :builtin_cognitive_classify, &cognitive_classify/1)
    Engine.register(:after_message, :builtin_log_response, &log_response/1)
    Engine.register(:after_message, :builtin_track_tokens, &track_token_usage/1)
    Engine.register(:after_message, :builtin_output_guard, &run_output_guard/1)
    Engine.register(:before_tool, :builtin_log_tool, &log_tool_invocation/1)
    Engine.register(:after_tool, :builtin_log_tool_result, &log_tool_result/1)
    Engine.register(:on_error, :builtin_log_error, &log_error/1)
    Engine.register(:on_compaction, :builtin_log_compaction, &log_compaction/1)
    Engine.register(:on_session_start, :builtin_cognitive_init, &cognitive_session_init/1)
    Engine.register(:on_session_end, :builtin_cognitive_summary, &cognitive_session_summary/1)
    :ok
  end

  defp log_inbound(%{session_id: sid} = ctx) do
    Logger.info("[#{sid}] inbound message")
    {:ok, Map.put(ctx, :received_at, System.monotonic_time(:millisecond))}
  end

  defp log_inbound(ctx), do: {:ok, ctx}

  defp check_rate_limit(%{session_id: sid, channel: channel} = ctx) do
    key = {:message, channel, sid}

    case Traitee.Security.RateLimiter.check(key) do
      :ok -> {:ok, ctx}
      {:error, :rate_limited, retry_after} -> {:halt, {:rate_limited, retry_after}}
    end
  end

  defp check_rate_limit(ctx), do: {:ok, ctx}

  defp log_response(%{session_id: sid} = ctx) do
    elapsed =
      case ctx[:received_at] do
        nil -> ""
        t -> " (#{System.monotonic_time(:millisecond) - t}ms)"
      end

    Logger.info("[#{sid}] response sent#{elapsed}")
    {:ok, ctx}
  end

  defp log_response(ctx), do: {:ok, ctx}

  defp track_token_usage(%{token_usage: usage, session_id: sid} = ctx) when is_map(usage) do
    :telemetry.execute(
      [:traitee, :llm, :tokens],
      usage,
      %{session_id: sid}
    )

    {:ok, ctx}
  end

  defp track_token_usage(ctx), do: {:ok, ctx}

  defp log_tool_invocation(%{tool_name: name, session_id: sid} = ctx) do
    Logger.info("[#{sid}] tool:#{name} invoked")
    {:ok, Map.put(ctx, :tool_started_at, System.monotonic_time(:millisecond))}
  end

  defp log_tool_invocation(ctx), do: {:ok, ctx}

  defp log_tool_result(%{tool_name: name, session_id: sid} = ctx) do
    elapsed =
      case ctx[:tool_started_at] do
        nil -> ""
        t -> " (#{System.monotonic_time(:millisecond) - t}ms)"
      end

    Logger.info("[#{sid}] tool:#{name} completed#{elapsed}")
    {:ok, ctx}
  end

  defp log_tool_result(ctx), do: {:ok, ctx}

  defp log_error(%{error: error, session_id: sid} = ctx) do
    Logger.error("[#{sid}] error: #{inspect(error)}")

    :telemetry.execute(
      [:traitee, :error],
      %{count: 1},
      %{session_id: sid, error: error}
    )

    {:ok, ctx}
  end

  defp log_error(%{error: error} = ctx) do
    Logger.error("error: #{inspect(error)}")
    {:ok, ctx}
  end

  defp log_error(ctx), do: {:ok, ctx}

  defp log_compaction(%{session_id: sid, before_count: before, after_count: after_c} = ctx) do
    Logger.info("[#{sid}] compaction: #{before} -> #{after_c} messages")
    {:ok, ctx}
  end

  defp log_compaction(ctx), do: {:ok, ctx}

  # -- Cognitive security hooks --

  defp cognitive_classify(%{session_id: sid, text: text} = ctx) do
    if Cognitive.enabled?() do
      regex_threats = Sanitizer.classify(text)

      judge_threats =
        if Judge.enabled?() do
          {:ok, verdict} = Judge.evaluate(text)
          Judge.to_threats(verdict)
        else
          []
        end

      all_threats = regex_threats ++ judge_threats

      if all_threats != [] do
        ThreatTracker.record_all(sid, all_threats)
        max_sev = Sanitizer.max_severity(all_threats)

        Logger.warning(
          "[#{sid}] cognitive: #{length(all_threats)} threat(s) detected, max_severity=#{max_sev}"
        )

        level = ThreatTracker.threat_level(sid)

        if level == :critical do
          Logger.error("[#{sid}] cognitive: session threat level CRITICAL")
        end

        {:ok,
         Map.merge(ctx, %{threats: all_threats, threat_level: level, has_recent_threats: true})}
      else
        {:ok, Map.put(ctx, :has_recent_threats, false)}
      end
    else
      {:ok, ctx}
    end
  end

  defp cognitive_classify(ctx), do: {:ok, ctx}

  defp run_output_guard(%{session_id: sid, response: response} = ctx) when is_binary(response) do
    if Cognitive.enabled?() do
      case OutputGuard.check(sid, response) do
        {:ok, _} ->
          {:ok, ctx}

        {:redacted, new_response} ->
          Logger.warning("[#{sid}] output_guard: response redacted")
          {:ok, Map.put(ctx, :response, new_response)}

        {:blocked, new_response} ->
          Logger.warning("[#{sid}] output_guard: response blocked")
          {:ok, Map.put(ctx, :response, new_response)}
      end
    else
      {:ok, ctx}
    end
  end

  defp run_output_guard(ctx), do: {:ok, ctx}

  defp cognitive_session_init(%{session_id: sid} = ctx) do
    if Cognitive.enabled?() do
      Canary.get_or_create(sid)
      Logger.debug("[#{sid}] cognitive security initialized")
    end

    {:ok, ctx}
  end

  defp cognitive_session_init(ctx), do: {:ok, ctx}

  defp cognitive_session_summary(%{session_id: sid} = ctx) do
    if Cognitive.enabled?() do
      summary = ThreatTracker.summary(sid)
      Logger.info("[#{sid}] session cognitive summary: #{summary}")
      ThreatTracker.clear(sid)
      Canary.clear(sid)
    end

    {:ok, ctx}
  end

  defp cognitive_session_summary(ctx), do: {:ok, ctx}
end
