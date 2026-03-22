defmodule Traitee.Daemon.Windows do
  @moduledoc "Windows Task Scheduler daemon management."

  @task_name "Traitee Gateway"

  @spec install(keyword()) :: :ok | {:error, term()}
  def install(_opts \\ []) do
    elixir = System.find_executable("elixir") || "elixir"
    project_dir = File.cwd!()
    command = "\"#{elixir}\" -S mix traitee.serve"

    schtasks(
      [
        "/create",
        "/tn",
        @task_name,
        "/tr",
        command,
        "/sc",
        "onlogon",
        "/rl",
        "highest",
        "/f"
      ],
      cd: project_dir
    )
  end

  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    schtasks(["/delete", "/tn", @task_name, "/f"])
  end

  @spec start() :: :ok | {:error, term()}
  def start do
    schtasks(["/run", "/tn", @task_name])
  end

  @spec stop() :: :ok | {:error, term()}
  def stop do
    schtasks(["/end", "/tn", @task_name])
  end

  @spec status() :: :running | :stopped | :not_installed
  def status do
    case System.cmd("schtasks", ["/query", "/tn", @task_name, "/fo", "csv", "/nh"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        cond do
          output =~ "Running" -> :running
          output =~ "Ready" -> :stopped
          true -> :stopped
        end

      _ ->
        :not_installed
    end
  rescue
    _ -> :not_installed
  end

  defp schtasks(args, opts \\ []) do
    cmd_opts = [stderr_to_stdout: true]
    cmd_opts = if opts[:cd], do: [{:cd, opts[:cd]} | cmd_opts], else: cmd_opts

    case System.cmd("schtasks", args, cmd_opts) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
