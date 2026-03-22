defmodule Traitee.Security.Allowlist do
  @moduledoc "Per-channel allowlist filtering."

  @spec allowed?(String.t(), atom()) :: boolean()
  def allowed?(sender_id, channel_type) do
    case Traitee.Config.get([:channels, channel_type, :allow_from]) do
      nil -> true
      [] -> true
      ["*"] -> true
      patterns when is_list(patterns) -> matches_any?(sender_id, patterns)
      _ -> true
    end
  end

  @spec dm_policy(atom()) :: :open | :pairing | :closed
  def dm_policy(channel_type) do
    case Traitee.Config.get([:channels, channel_type, :dm_policy]) do
      policy when policy in [:open, :pairing, :closed] -> policy
      "open" -> :open
      "pairing" -> :pairing
      "closed" -> :closed
      _ -> :pairing
    end
  end

  defp matches_any?(sender_id, patterns) do
    Enum.any?(patterns, &glob_match?(sender_id, &1))
  end

  defp glob_match?(value, pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    Regex.match?(~r/^#{regex}$/, value)
  end
end
