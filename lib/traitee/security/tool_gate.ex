defmodule Traitee.Security.ToolGate do
  @moduledoc """
  Ownership / authorization gate used by self-modifying or high-impact
  tools (workspace_edit, skill_manage, channel_send, cron).

  Most tools should run regardless of who the user is, but some tools
  let the LLM rewrite its own identity (SOUL.md), send messages to
  unrelated channels, or schedule background work — in those cases we
  refuse unless the originating sender is the configured owner.

  Args passed by `Session.Server.execute_tools/2` include:
    * `_session_id` — the session identifier
    * `_session_sender_id` — most-recently-seen sender on any channel
    * `_session_channel_type` — corresponding channel atom
    * `_session_is_owner` — precomputed boolean (optional, set by the
      session server when the call originates from an owner-operated
      session)
  """

  alias Traitee.Config

  @doc """
  Returns `:ok` if the originating caller appears to be the configured
  owner, or an `{:error, reason}` tuple otherwise.

  Accepts the LLM tool args map directly.
  """
  @spec require_owner(map(), String.t()) :: :ok | {:error, String.t()}
  def require_owner(args, tool_name) when is_map(args) do
    cond do
      args["_session_is_owner"] == true ->
        :ok

      is_binary(args["_session_sender_id"]) and args["_session_channel_type"] != nil ->
        channel = args["_session_channel_type"]

        if Config.sender_is_owner?(args["_session_sender_id"], channel) do
          :ok
        else
          deny(tool_name)
        end

      # No sender context available — be safe and refuse unless the
      # operator explicitly opts in to unrestricted self-modification.
      self_mod_allowed?() ->
        :ok

      true ->
        deny(tool_name)
    end
  end

  @doc """
  Returns whether the configured operator has opted IN to permitting
  dangerous self-modification from non-owner sessions. Default: false.
  """
  @spec self_mod_allowed?() :: boolean()
  def self_mod_allowed? do
    Config.get([:security, :allow_self_modification_from_any_session]) == true
  rescue
    _ -> false
  end

  defp deny(tool_name) do
    {:error,
     "Tool '#{tool_name}' is owner-only: the current session is not owner-authenticated. " <>
       "Set `security.allow_self_modification_from_any_session = true` to opt out."}
  end
end
