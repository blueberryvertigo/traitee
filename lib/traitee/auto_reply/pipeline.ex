defmodule Traitee.AutoReply.Pipeline do
  @moduledoc "Message processing pipeline: debounce, commands, group activation, skill triggering."

  alias Traitee.AutoReply.{CommandRegistry, Debouncer}
  alias Traitee.Skills.Loader

  require Logger

  @type result ::
          {:reply, String.t()}
          | {:command, term()}
          | {:skill, String.t()}
          | :debounced
          | :ignored

  @spec process(map(), map()) :: result()
  def process(inbound, session_state) do
    with :ok <- debounce_stage(inbound),
         :ok <- group_activation_stage(inbound, session_state),
         {:pass, inbound} <- command_stage(inbound),
         {:pass, context} <- skill_stage(inbound),
         :ok <- security_stage(inbound) do
      {:reply, context}
    end
  end

  defp debounce_stage(%{sender_id: sender_id, text: text}) do
    case Debouncer.debounce(sender_id, text) do
      :ok -> :ok
      :buffered -> :debounced
    end
  end

  defp group_activation_stage(%{metadata: %{chat_type: type}} = inbound, session_state)
       when type in ["group", "supergroup"] do
    activation = Map.get(session_state, :group_activation, :mention)

    case activation do
      :always ->
        :ok

      :mention ->
        bot_name = Traitee.Config.get([:agent, :bot_name]) || "traitee"

        if mentioned?(inbound.text, bot_name),
          do: :ok,
          else: :ignored
    end
  end

  defp group_activation_stage(_inbound, _session_state), do: :ok

  defp command_stage(%{text: "/" <> _ = text} = inbound) do
    case CommandRegistry.execute(text, %{inbound: inbound}) do
      {:ok, response} -> {:command, response}
      {:error, :unknown_command} -> {:pass, inbound}
      {:error, reason} -> {:command, {:error, reason}}
    end
  end

  defp command_stage(inbound), do: {:pass, inbound}

  defp skill_stage(inbound) do
    case match_skill(inbound.text) do
      nil -> {:pass, inbound.text}
      content -> {:skill, content}
    end
  end

  defp security_stage(%{sender_id: sender_id}) do
    check_rate_limit(sender_id)
  end

  defp mentioned?(text, bot_name) do
    lower = String.downcase(text)
    String.contains?(lower, ["@#{bot_name}", String.downcase(bot_name)])
  end

  defp match_skill(text) do
    case Loader.match_skills(text) do
      [best | _] ->
        case Loader.load_skill(best.name) do
          {:ok, content} -> content
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp check_rate_limit(_sender_id), do: :ok
end
