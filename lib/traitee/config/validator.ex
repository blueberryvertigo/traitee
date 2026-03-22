defmodule Traitee.Config.Validator do
  @moduledoc "Config validation with structured error reporting."

  @model_pattern ~r/^[a-z0-9_-]+\/[a-z0-9._-]+$/i

  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(config) when is_map(config) do
    errors =
      []
      |> validate_agent(config[:agent])
      |> validate_channels(config[:channels])
      |> validate_memory(config[:memory])
      |> validate_gateway(config[:gateway])
      |> validate_tools(config[:tools])
      |> Enum.reverse()

    if errors == [], do: {:ok, config}, else: {:error, errors}
  end

  @spec validate_section(atom(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_section(:agent, section), do: check([], &validate_agent(&1, section))
  def validate_section(:channels, section), do: check([], &validate_channels(&1, section))
  def validate_section(:memory, section), do: check([], &validate_memory(&1, section))
  def validate_section(:gateway, section), do: check([], &validate_gateway(&1, section))
  def validate_section(:tools, section), do: check([], &validate_tools(&1, section))
  def validate_section(name, _section), do: {:error, ["unknown section: #{name}"]}

  @spec warnings(map()) :: [String.t()]
  def warnings(config) do
    []
    |> warn_if(
      missing_key?(config, [:channels, :discord, :token]) &&
        missing_key?(config, [:channels, :telegram, :token]),
      "No channel tokens configured — bot won't receive messages"
    )
    |> warn_if(missing_key?(config, [:agent, :model]), "No LLM model configured")
    |> Enum.reverse()
  end

  # -- Agent --

  defp validate_agent(errors, nil), do: errors

  defp validate_agent(errors, agent) do
    errors
    |> validate_model_format(agent[:model], "agent.model")
    |> validate_model_format(agent[:fallback_model], "agent.fallback_model")
  end

  defp validate_model_format(errors, nil, _field), do: errors

  defp validate_model_format(errors, model, field) when is_binary(model) do
    if Regex.match?(@model_pattern, model),
      do: errors,
      else: ["#{field} must match 'provider/model' format, got: #{model}" | errors]
  end

  defp validate_model_format(errors, _model, field) do
    ["#{field} must be a string" | errors]
  end

  # -- Channels --

  defp validate_channels(errors, nil), do: errors

  defp validate_channels(errors, channels) do
    errors
    |> validate_channel_token(channels[:discord], "channels.discord")
    |> validate_channel_token(channels[:telegram], "channels.telegram")
    |> validate_channel_token(channels[:whatsapp], "channels.whatsapp")
  end

  defp validate_channel_token(errors, nil, _prefix), do: errors

  defp validate_channel_token(errors, %{enabled: true, token: token}, prefix)
       when is_nil(token) or token == "" do
    ["#{prefix} is enabled but has no token" | errors]
  end

  defp validate_channel_token(errors, _channel, _prefix), do: errors

  # -- Memory --

  defp validate_memory(errors, nil), do: errors

  defp validate_memory(errors, memory) do
    errors
    |> validate_pos_int(memory[:stm_capacity], "memory.stm_capacity")
    |> validate_pos_int(memory[:mtm_chunk_size], "memory.mtm_chunk_size")
  end

  defp validate_pos_int(errors, nil, _field), do: errors

  defp validate_pos_int(errors, val, _field) when is_integer(val) and val > 0, do: errors

  defp validate_pos_int(errors, val, field) do
    ["#{field} must be a positive integer, got: #{inspect(val)}" | errors]
  end

  # -- Gateway --

  defp validate_gateway(errors, nil), do: errors

  defp validate_gateway(errors, gateway) do
    case gateway[:port] do
      nil -> errors
      port when is_integer(port) and port >= 1 and port <= 65_535 -> errors
      port -> ["gateway.port must be 1-65535, got: #{inspect(port)}" | errors]
    end
  end

  # -- Tools --

  defp validate_tools(errors, nil), do: errors

  defp validate_tools(errors, tools) do
    Enum.reduce(tools, errors, fn
      {_name, %{enabled: enabled}}, acc when is_boolean(enabled) ->
        acc

      {name, %{enabled: val}}, acc ->
        ["tools.#{name}.enabled must be boolean, got: #{inspect(val)}" | acc]

      _, acc ->
        acc
    end)
  end

  # -- Helpers --

  defp check(errors, fun) do
    result = fun.(errors) |> Enum.reverse()
    if result == [], do: {:ok, %{}}, else: {:error, result}
  end

  defp missing_key?(config, path) do
    val = get_in_map(config, path)
    is_nil(val) or val == ""
  end

  defp get_in_map(map, []) when is_map(map), do: map
  defp get_in_map(map, [k | rest]) when is_map(map), do: get_in_map(Map.get(map, k), rest)
  defp get_in_map(_, _), do: nil

  defp warn_if(warnings, true, msg), do: [msg | warnings]
  defp warn_if(warnings, false, _msg), do: warnings
end
