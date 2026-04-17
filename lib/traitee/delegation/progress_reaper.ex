defmodule Traitee.Delegation.ProgressReaper do
  @moduledoc """
  Periodic sweeper for stale entries in `Traitee.Delegation.Progress`.

  Without this, crashed subagents or sessions that died between a
  progress update and a clear_session/1 left entries in ETS forever.
  """
  use GenServer

  alias Traitee.Delegation.Progress

  @interval_ms 5 * 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reap, state) do
    Progress.reap_stale()
    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(self(), :reap, @interval_ms)
  end
end
