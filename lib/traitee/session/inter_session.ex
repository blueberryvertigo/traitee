defmodule Traitee.Session.InterSession do
  @moduledoc "Tools for session-to-session communication."

  alias Traitee.Session
  alias Traitee.Session.Server, as: SessionServer

  @spec list_sessions() :: [map()]
  def list_sessions do
    caller = self()

    Session.list_active()
    |> Enum.map(fn {session_id, pid} ->
      if pid == caller do
        %{session_id: session_id, note: "current session"}
      else
        case SessionServer.get_state(pid) do
          %{} = state -> Map.take(state, [:session_id, :channel, :message_count, :created_at])
          _ -> %{session_id: session_id}
        end
      end
    end)
  end

  @spec get_history(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def get_history(session_id, limit \\ 20) do
    case Registry.lookup(Traitee.Session.Registry, session_id) do
      [{pid, _}] ->
        if pid == self() do
          {:error, :cannot_query_own_session}
        else
          state = SessionServer.get_state(pid)
          messages = Traitee.Memory.STM.get_recent(state[:stm_state] || state, limit)
          {:ok, messages}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  # Cap inter-session hops to prevent A→B→A→… ping-pong loops that would
  # otherwise spawn the full security+memory pipeline per hop and eventually
  # DoS the node's LLM budget.
  @max_inter_session_hops 2

  @spec send_to_session(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send_to_session(from_session_id, to_session_id, message, opts \\ []) do
    hop = Keyword.get(opts, :hop, 0)

    cond do
      hop >= @max_inter_session_hops ->
        {:error, :inter_session_hop_limit}

      from_session_id == to_session_id ->
        {:error, :cannot_message_own_session}

      true ->
        case Registry.lookup(Traitee.Session.Registry, to_session_id) do
          [{pid, _}] ->
            if pid == self() do
              {:error, :cannot_message_own_session}
            else
              prefixed = "[from #{from_session_id}] #{message}"

              # Pass the incremented hop count through as a message option so
              # downstream `sessions.send` calls in the target session know
              # they're an inter-session descendant.
              SessionServer.send_message(pid, prefixed, :inter_session,
                inter_session_depth: hop + 1,
                sender_id: "inter_session:#{from_session_id}"
              )
            end

          [] ->
            {:error, :session_not_found}
        end
    end
  end

  @spec to_tool_schemas() :: [map()]
  def to_tool_schemas do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "sessions_list",
          "description" => "List all active sessions with metadata.",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "sessions_history",
          "description" => "Get recent messages from another session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "session_id" => %{"type" => "string", "description" => "Target session ID"},
              "limit" => %{
                "type" => "integer",
                "description" => "Max messages to return",
                "default" => 20
              }
            },
            "required" => ["session_id"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "sessions_send",
          "description" => "Send a message to another session.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "to_session_id" => %{"type" => "string", "description" => "Target session ID"},
              "message" => %{"type" => "string", "description" => "Message to send"}
            },
            "required" => ["to_session_id", "message"]
          }
        }
      }
    ]
  end
end
