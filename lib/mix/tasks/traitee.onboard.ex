defmodule Mix.Tasks.Traitee.Onboard do
  use Mix.Task

  @shortdoc "Interactive setup wizard"

  @moduledoc """
  Runs the interactive onboarding wizard to configure Traitee.

      $ mix traitee.onboard

  Walks through LLM provider setup, channel configuration,
  workspace initialization, and optional daemon installation.
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Traitee.Onboard.Wizard.run()
  end
end
