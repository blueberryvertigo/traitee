defmodule Traitee.Tools.Sessions do
  @moduledoc "Session management tools for LLM function calling."

  @behaviour Traitee.Tools.Tool

  alias Traitee.Session.InterSession

  @impl true
  def name, do: "sessions"

  @impl true
  def description do
    "Manage sessions: list active sessions, view history, or send messages between sessions."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "history", "send"],
          "description" => "Action: list sessions, get history, or send a message"
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Target session ID (required for history and send)"
        },
        "message" => %{
          "type" => "string",
          "description" => "Message to send (required for send action)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max messages to return for history (default 20)",
          "default" => 20
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(%{"action" => "list"}) do
    sessions = InterSession.list_sessions()

    if sessions == [] do
      {:ok, "No active sessions."}
    else
      formatted =
        sessions
        |> Enum.map(fn s ->
          id = s[:session_id] || "unknown"
          channel = s[:channel] || "unknown"
          count = s[:message_count] || 0
          "#{id} (#{channel}, #{count} messages)"
        end)
        |> Enum.join("\n")

      {:ok, formatted}
    end
  end

  def execute(%{"action" => "history", "session_id" => sid} = args) do
    limit = args["limit"] || 20

    case InterSession.get_history(sid, limit) do
      {:ok, messages} ->
        formatted =
          messages
          |> Enum.map(fn msg ->
            role = msg[:role] || msg["role"] || "unknown"
            content = msg[:content] || msg["content"] || ""
            "[#{role}] #{content}"
          end)
          |> Enum.join("\n")

        {:ok, formatted}

      {:error, :session_not_found} ->
        {:error, "Session #{sid} not found."}

      {:error, :cannot_query_own_session} ->
        {:error, "Cannot query the current session's history."}
    end
  end

  def execute(%{"action" => "history"}) do
    {:error, "Missing required parameter: session_id"}
  end

  def execute(%{"action" => "send", "session_id" => sid, "message" => msg} = args) do
    from = args["from_session_id"] || "system"

    case InterSession.send_to_session(from, sid, msg) do
      :ok ->
        {:ok, "Message sent to session #{sid}."}

      {:ok, _response} ->
        {:ok, "Message sent to session #{sid}."}

      {:error, :session_not_found} ->
        {:error, "Session #{sid} not found."}

      {:error, :cannot_message_own_session} ->
        {:error, "Cannot send a message to the current session."}

      {:error, reason} ->
        {:error, "Failed to send: #{inspect(reason)}"}
    end
  end

  def execute(%{"action" => "send"}) do
    {:error, "Missing required parameters: session_id, message"}
  end

  def execute(%{"action" => action}) do
    {:error, "Unknown action: #{action}. Supported: list, history, send"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}
end
