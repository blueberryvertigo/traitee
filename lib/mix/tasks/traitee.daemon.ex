defmodule Mix.Tasks.Traitee.Daemon do
  use Mix.Task

  @shortdoc "Manage background service"

  @moduledoc """
  Manages Traitee as a background system service.

      $ mix traitee.daemon install    # Install as a service
      $ mix traitee.daemon uninstall  # Remove the service
      $ mix traitee.daemon start      # Start the service
      $ mix traitee.daemon stop       # Stop the service
      $ mix traitee.daemon status     # Check service status
  """

  alias Traitee.Daemon.Service

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["install" | rest] -> handle_install(rest)
      ["uninstall"] -> handle(:uninstall, &Service.uninstall/0)
      ["start"] -> handle(:start, &Service.start/0)
      ["stop"] -> handle(:stop, &Service.stop/0)
      ["status"] -> handle_status()
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  defp handle_install(_rest) do
    Mix.shell().info("Installing Traitee service (#{Service.platform()})...")

    case Service.install() do
      :ok -> Mix.shell().info("Service installed successfully.")
      {:error, reason} -> Mix.shell().error("Install failed: #{inspect(reason)}")
    end
  end

  defp handle(action, fun) do
    Mix.shell().info("#{action |> to_string() |> String.capitalize()}ing service...")

    case fun.() do
      :ok -> Mix.shell().info("Done.")
      {:error, reason} -> Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp handle_status do
    case Service.status() do
      :running -> Mix.shell().info("Traitee service is running.")
      :stopped -> Mix.shell().info("Traitee service is stopped.")
      :not_installed -> Mix.shell().info("Traitee service is not installed.")
    end
  end
end
