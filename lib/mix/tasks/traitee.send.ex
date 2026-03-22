defmodule Mix.Tasks.Traitee.Send do
  @moduledoc """
  Send a one-shot message through the AI assistant.

      mix traitee.send "What is the meaning of life?"
      mix traitee.send --channel discord --to "#general" "Hello!"
  """
  use Mix.Task

  @shortdoc "Send a one-shot message"

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [channel: :string, to: :string],
        aliases: [c: :channel, t: :to]
      )

    message = Enum.join(positional, " ")

    if message == "" do
      Mix.shell().error("Usage: mix traitee.send [--channel CH --to TARGET] \"message\"")
      System.halt(1)
    end

    Mix.Task.run("app.start")

    channel = opts[:channel]

    if channel && opts[:to] do
      send_to_channel(channel, opts[:to], message)
    else
      send_direct(message)
    end
  end

  defp send_direct(message) do
    IO.write("Thinking... ")

    case Traitee.LLM.Router.complete(%{messages: [%{role: "user", content: message}]}) do
      {:ok, response} ->
        IO.puts("")
        IO.puts(response.content)

      {:error, reason} ->
        IO.puts("")
        Mix.shell().error("Error: #{inspect(reason)}")
    end
  end

  defp send_to_channel(channel, target, message) do
    outbound = %{
      text: message,
      channel_type: String.to_atom(channel),
      target: target,
      reply_to: nil,
      metadata: %{}
    }

    module =
      case channel do
        "discord" ->
          Traitee.Channels.Discord

        "telegram" ->
          Traitee.Channels.Telegram

        "whatsapp" ->
          Traitee.Channels.WhatsApp

        "signal" ->
          Traitee.Channels.Signal

        _ ->
          Mix.shell().error("Unknown channel: #{channel}")
          System.halt(1)
      end

    case module.send_message(outbound) do
      :ok -> IO.puts("Message sent to #{channel}:#{target}")
      {:error, reason} -> Mix.shell().error("Send failed: #{inspect(reason)}")
    end
  end
end
