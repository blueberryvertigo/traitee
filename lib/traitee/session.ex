defmodule Traitee.Session do
  @moduledoc """
  Session management facade. Looks up or spawns session GenServers
  via the DynamicSupervisor and Registry.
  """

  alias Traitee.Session.Server

  @doc """
  Ensures a session process is running for the given session_id.
  Returns `{:ok, pid}` of the existing or newly started session.
  """
  def ensure_started(session_id, channel_type) do
    case Registry.lookup(Traitee.Session.Registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          Traitee.Session.Supervisor,
          {Server, session_id: session_id, channel: channel_type}
        )
    end
  end

  @doc """
  Lists all active session IDs.
  """
  def list_active do
    Registry.select(Traitee.Session.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Terminates a session.
  """
  def terminate(session_id) do
    case Registry.lookup(Traitee.Session.Registry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Traitee.Session.Supervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Injects an async tool result into a running session's STM.
  Used by delegate_task to deliver subagent results in the background.
  """
  def inject_async_result(nil, _result), do: :ok

  def inject_async_result(session_id, result) do
    case Registry.lookup(Traitee.Session.Registry, session_id) do
      [{pid, _}] -> send(pid, {:async_tool_result, result})
      [] -> :ok
    end
  end
end
