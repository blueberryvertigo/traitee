defmodule Traitee.Routing.Bindings do
  @moduledoc "Route binding configuration and matching."

  defstruct [:agent_id, :match_type, :match_value, :workspace, :model, :dm_scope, :priority]

  @type match_type :: :peer | :guild | :account | :channel | :default
  @type dm_scope :: :main | :per_peer | :per_channel_peer
  @type t :: %__MODULE__{
          agent_id: String.t(),
          match_type: match_type(),
          match_value: String.t() | atom() | nil,
          workspace: String.t(),
          model: String.t() | nil,
          dm_scope: dm_scope(),
          priority: integer()
        }

  @priority_order %{peer: 0, guild: 1, account: 2, channel: 3, default: 4}

  def load do
    Traitee.Config.get([:routing, :bindings])
    |> List.wrap()
    |> Enum.map(&parse_binding/1)
    |> Enum.sort_by(& &1.priority)
  end

  def match(bindings, inbound) when is_list(bindings) do
    Enum.find(bindings, &binding_matches?(&1, inbound))
  end

  defp parse_binding(raw) when is_map(raw) do
    {match_type, match_value} = parse_match(raw[:match] || raw["match"])

    %__MODULE__{
      agent_id: raw[:agent_id] || raw["agent_id"] || "default",
      match_type: match_type,
      match_value: match_value,
      workspace: raw[:workspace] || raw["workspace"] || default_workspace(),
      model: raw[:model] || raw["model"],
      dm_scope: parse_dm_scope(raw[:dm_scope] || raw["dm_scope"]),
      priority: Map.get(@priority_order, match_type, 99)
    }
  end

  defp parse_match(:default), do: {:default, nil}
  defp parse_match("default"), do: {:default, nil}
  defp parse_match(nil), do: {:default, nil}

  defp parse_match(m) when is_map(m) do
    cond do
      m[:peer] || m["peer"] -> {:peer, m[:peer] || m["peer"]}
      m[:guild] || m["guild"] -> {:guild, m[:guild] || m["guild"]}
      m[:account] || m["account"] -> {:account, m[:account] || m["account"]}
      m[:channel] || m["channel"] -> {:channel, normalize_channel(m[:channel] || m["channel"])}
      true -> {:default, nil}
    end
  end

  defp parse_match(_), do: {:default, nil}

  defp binding_matches?(%{match_type: :default}, _inbound), do: true

  defp binding_matches?(%{match_type: :peer, match_value: val}, inbound) do
    to_string(inbound[:sender_id]) == to_string(val)
  end

  defp binding_matches?(%{match_type: :guild, match_value: val}, inbound) do
    to_string(inbound[:guild_id] || inbound[:server_id]) == to_string(val)
  end

  defp binding_matches?(%{match_type: :account, match_value: val}, inbound) do
    to_string(inbound[:account] || inbound[:phone_number]) == to_string(val)
  end

  defp binding_matches?(%{match_type: :channel, match_value: val}, inbound) do
    inbound[:channel_type] == val
  end

  defp normalize_channel(ch) when is_atom(ch), do: ch
  defp normalize_channel(ch) when is_binary(ch), do: String.to_existing_atom(ch)
  defp normalize_channel(ch), do: ch

  defp parse_dm_scope(:per_peer), do: :per_peer
  defp parse_dm_scope("per_peer"), do: :per_peer
  defp parse_dm_scope(:per_channel_peer), do: :per_channel_peer
  defp parse_dm_scope("per_channel_peer"), do: :per_channel_peer
  defp parse_dm_scope(_), do: :main

  defp default_workspace do
    Path.join(Traitee.data_dir(), "workspace")
  end
end
