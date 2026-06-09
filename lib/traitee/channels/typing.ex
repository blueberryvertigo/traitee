defmodule Traitee.Channels.Typing do
  @moduledoc "Typing indicator lifecycle management."

  @refresh_ms 5_000

  @doc """
  Starts a typing-indicator loop and returns its pid. The loop is linked to
  the calling process and stops on its own once the caller dies, so call
  `start/2` from the process that handles the response (and pass the returned
  pid lexically to `stop/1` — never via the process dictionary, which doesn't
  cross process boundaries).
  """
  @spec start(atom(), String.t()) :: pid()
  def start(channel_type, target) do
    parent = self()

    spawn_link(fn ->
      send_typing(channel_type, target)
      typing_loop(channel_type, target, parent)
    end)
  end

  @spec stop(pid() | nil) :: :ok
  def stop(pid) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  def stop(_), do: :ok

  # -- Private --

  defp typing_loop(channel_type, target, parent) do
    receive do
      :stop -> :ok
    after
      @refresh_ms ->
        if Process.alive?(parent) do
          send_typing(channel_type, target)
          typing_loop(channel_type, target, parent)
        end
    end
  end

  defp send_typing(:discord, channel_id) do
    Nostrum.Api.Channel.start_typing(String.to_integer(channel_id))
  rescue
    _ -> :ok
  end

  defp send_typing(:telegram, chat_id) do
    config = Traitee.Config.get([:channels, :telegram]) || %{}
    token = config[:token]

    if token do
      url = "https://api.telegram.org/bot#{token}/sendChatAction"
      Req.post(url, json: %{chat_id: chat_id, action: "typing"}, retry: false)
    end

    :ok
  end

  defp send_typing(:webchat, target) do
    Phoenix.PubSub.broadcast(Traitee.PubSub, "webchat:#{target}", :typing)
    :ok
  end

  defp send_typing(_channel_type, _target), do: :ok
end
