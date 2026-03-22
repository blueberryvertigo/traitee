defmodule Mix.Tasks.Traitee.Serve do
  @moduledoc """
  Start the Traitee gateway -- all channels, WebSocket server, and tools.

      mix traitee.serve
      mix traitee.serve --port 4000
  """
  use Mix.Task

  @shortdoc "Start the Traitee gateway"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [port: :integer],
        aliases: [p: :port]
      )

    if port = opts[:port] do
      Application.put_env(
        :traitee,
        TraiteeWeb.Endpoint,
        Keyword.merge(
          Application.get_env(:traitee, TraiteeWeb.Endpoint, []),
          http: [port: port]
        )
      )
    end

    Mix.Task.run("app.start")

    config = Traitee.Config.all()
    IO.puts(banner(config))

    unless iex_running?() do
      Process.sleep(:infinity)
    end
  end

  defp banner(config) do
    model = get_in(config, [:agent, :model]) || "not configured"
    port = get_in(Application.get_env(:traitee, TraiteeWeb.Endpoint, []), [:http, :port]) || 4000

    channels =
      [:discord, :telegram, :whatsapp, :signal]
      |> Enum.filter(fn ch -> get_in(config, [:channels, ch, :enabled]) end)
      |> Enum.map(&to_string/1)
      |> case do
        [] -> "none"
        list -> Enum.join(list, ", ")
      end

    """

    ╔══════════════════════════════════════╗
    ║      Traitee Gateway v0.1.0         ║
    ╚══════════════════════════════════════╝

    Model:    #{model}
    Channels: #{channels}
    WebChat:  http://localhost:#{port}/ws
    API:      http://localhost:#{port}/api

    Gateway running. Press Ctrl+C to stop.
    """
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
