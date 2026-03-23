defmodule Mix.Tasks.Traitee.Serve do
  @moduledoc """
  Start the Traitee gateway -- all channels, WebSocket server, and tools.

      mix traitee.serve
      mix traitee.serve --port 4000
  """
  use Mix.Task

  alias Traitee.CLI.Display

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
    IO.puts(Display.serve_banner(config))

    unless iex_running?() do
      Process.sleep(:infinity)
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
