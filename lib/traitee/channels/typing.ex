defmodule Traitee.Channels.Typing do
  @moduledoc "Typing indicator lifecycle management."

  @refresh_ms 5_000

  @spec start(atom(), String.t()) :: reference()
  def start(channel_type, target) do
    ref = make_ref()
    parent = self()

    pid =
      spawn_link(fn ->
        send_typing(channel_type, target)
        typing_loop(channel_type, target, parent, ref)
      end)

    Process.put({__MODULE__, ref}, pid)
    ref
  end

  @spec stop(reference()) :: :ok
  def stop(ref) do
    case Process.get({__MODULE__, ref}) do
      pid when is_pid(pid) ->
        Process.unlink(pid)
        Process.exit(pid, :shutdown)
        Process.delete({__MODULE__, ref})

      _ ->
        :ok
    end

    :ok
  end

  # -- Private --

  defp typing_loop(channel_type, target, parent, ref) do
    receive do
      :stop -> :ok
    after
      @refresh_ms ->
        if Process.alive?(parent) do
          send_typing(channel_type, target)
          typing_loop(channel_type, target, parent, ref)
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
