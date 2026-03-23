defmodule Mix.Tasks.Traitee.Doctor do
  @moduledoc """
  Run system diagnostics.

      mix traitee.doctor
  """
  use Mix.Task

  alias Traitee.CLI.Display

  @shortdoc "Run system diagnostics"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    results = Traitee.Doctor.run_all()
    IO.puts(Display.format_doctor_report(results))

    has_errors = Enum.any?(results, fn %{status: s} -> s == :error end)
    if has_errors, do: System.halt(1)
  end
end
