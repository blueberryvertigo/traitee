defmodule Traitee.Skills.Registry do
  @moduledoc """
  GenServer maintaining the skill catalog. Periodically re-scans for
  new or changed skills and tracks which skills have been loaded per session.
  """

  use GenServer

  alias Traitee.Skills.Loader

  @scan_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_active_skills do
    GenServer.call(__MODULE__, :get_active_skills)
  end

  def trigger_skill(skill_name, session_id) do
    GenServer.call(__MODULE__, {:trigger_skill, skill_name, session_id})
  end

  @impl true
  def init(_opts) do
    state = %{
      skills: Loader.scan(),
      loaded_sessions: %{}
    }

    schedule_scan()
    {:ok, state}
  end

  @impl true
  def handle_call(:get_active_skills, _from, state) do
    active = Enum.filter(state.skills, & &1.enabled)
    {:reply, active, state}
  end

  def handle_call({:trigger_skill, skill_name, session_id}, _from, state) do
    session_key = {session_id, skill_name}

    if Map.has_key?(state.loaded_sessions, session_key) do
      {:reply, {:already_loaded, skill_name}, state}
    else
      case Loader.load_skill(skill_name) do
        {:ok, content} ->
          loaded = Map.put(state.loaded_sessions, session_key, true)
          {:reply, {:ok, content}, %{state | loaded_sessions: loaded}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(:scan, state) do
    Loader.invalidate_cache()
    skills = Loader.scan()
    schedule_scan()
    {:noreply, %{state | skills: skills}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_scan do
    Process.send_after(self(), :scan, @scan_interval_ms)
  end
end
