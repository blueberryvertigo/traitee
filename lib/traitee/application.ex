defmodule Traitee.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    ensure_data_dir!()
    Traitee.Workspace.ensure_workspace!()
    Traitee.Tools.Registry.init()
    Traitee.Security.RateLimiter.init()
    Traitee.Security.ThreatTracker.init()
    Traitee.Security.Canary.init()
    Traitee.Security.Filesystem.init()
    Traitee.Memory.Vector.init()
    Traitee.Tools.TaskTracker.init()
    Traitee.ActivityLog.init()

    children = [
      Traitee.Repo,
      {Phoenix.PubSub, name: Traitee.PubSub},
      Traitee.Hooks.Engine,
      Traitee.Config.HotReload,
      Traitee.LLM.Router,
      Traitee.Memory.Compactor,
      Traitee.Memory.BatchEmbedder,
      Traitee.Skills.Registry,
      Traitee.Security.Audit,
      Traitee.Security.Pairing,
      Traitee.AutoReply.Debouncer,
      Traitee.Cron.Scheduler,
      {Registry, keys: :unique, name: Traitee.Session.Registry},
      {DynamicSupervisor, name: Traitee.Session.Supervisor, strategy: :one_for_one},
      Traitee.Channels.Supervisor,
      {DynamicSupervisor, name: Traitee.Tools.Supervisor, strategy: :one_for_one},
      Traitee.Browser.Supervisor,
      Traitee.Process.Lanes,
      TraiteeWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Traitee.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Task.start(fn -> Traitee.Hooks.Builtin.register_all() end)
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    TraiteeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp ensure_data_dir! do
    dir = Traitee.data_dir()
    File.mkdir_p!(dir)
  end
end
