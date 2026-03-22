defmodule Traitee.Routing.AgentRouter do
  @moduledoc "Multi-agent routing with tiered priority matching."

  alias Traitee.Routing.Bindings

  @ets_table :traitee_route_cache
  @ttl_ms 60_000

  def init do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end

  def resolve(inbound) do
    cache_key = cache_key(inbound)

    case lookup_cache(cache_key) do
      {:ok, route} ->
        route

      :miss ->
        route = do_resolve(inbound)
        store_cache(cache_key, route)
        route
    end
  end

  def build_session_key(agent_id, inbound, dm_scope \\ :main) do
    base = "#{agent_id}"
    sender_id = normalize_sender(inbound[:sender_id], inbound[:channel_type])

    case dm_scope do
      :main ->
        base

      :per_peer ->
        "#{base}:#{sender_id}"

      :per_channel_peer ->
        "#{base}:#{inbound[:channel_type]}:#{sender_id}"
    end
  end

  defp normalize_sender(sender_id, channel_type) do
    if Traitee.Config.sender_is_owner?(sender_id, channel_type) do
      Traitee.Config.get([:security, :owner_id]) || sender_id
    else
      sender_id
    end
  end

  def invalidate_cache do
    init()
    :ets.delete_all_objects(@ets_table)
    :ok
  end

  defp do_resolve(inbound) do
    bindings = Bindings.load()

    case Bindings.match(bindings, inbound) do
      nil ->
        default_route(inbound)

      binding ->
        session_key = build_session_key(binding.agent_id, inbound, binding.dm_scope)

        %{
          agent_id: binding.agent_id,
          workspace: binding.workspace,
          model: binding.model,
          session_key: session_key,
          dm_scope: binding.dm_scope
        }
    end
  end

  defp default_route(inbound) do
    agent_id = "default"
    session_key = build_session_key(agent_id, inbound, :per_peer)

    %{
      agent_id: agent_id,
      workspace: Path.join(Traitee.data_dir(), "workspace"),
      model: nil,
      session_key: session_key,
      dm_scope: :per_peer
    }
  end

  defp cache_key(inbound) do
    {
      inbound[:sender_id],
      inbound[:channel_type],
      inbound[:guild_id] || inbound[:server_id],
      inbound[:account] || inbound[:phone_number]
    }
  end

  defp lookup_cache(key) do
    init()

    case :ets.lookup(@ets_table, key) do
      [{^key, route, ts}] ->
        if System.monotonic_time(:millisecond) - ts < @ttl_ms do
          {:ok, route}
        else
          :ets.delete(@ets_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp store_cache(key, route) do
    init()
    :ets.insert(@ets_table, {key, route, System.monotonic_time(:millisecond)})
  end
end
