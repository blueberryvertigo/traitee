defmodule Traitee.Hooks.Engine do
  @moduledoc "Event hook system for extensible automation."
  use GenServer

  require Logger

  @type hook_point ::
          :before_message
          | :after_message
          | :before_tool
          | :after_tool
          | :on_error
          | :on_session_start
          | :on_session_end
          | :on_compaction
          | :on_config_change

  @type handler :: (map() -> {:ok, map()} | {:halt, term()})

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(hook_point(), atom() | String.t(), handler()) :: :ok
  def register(hook_point, name, handler) when is_function(handler, 1) do
    GenServer.call(__MODULE__, {:register, hook_point, name, handler})
  end

  @spec unregister(hook_point(), atom() | String.t()) :: :ok
  def unregister(hook_point, name) do
    GenServer.call(__MODULE__, {:unregister, hook_point, name})
  end

  @spec fire(hook_point(), map()) :: {:ok, map()} | {:halt, term()}
  def fire(hook_point, context) do
    GenServer.call(__MODULE__, {:fire, hook_point, context}, :infinity)
  end

  @spec fire_async(hook_point(), map()) :: :ok
  def fire_async(hook_point, context) do
    GenServer.cast(__MODULE__, {:fire, hook_point, context})
  end

  @spec list(hook_point()) :: [{atom() | String.t(), handler()}]
  def list(hook_point) do
    GenServer.call(__MODULE__, {:list, hook_point})
  end

  # -- Server --

  @impl true
  def init(_opts) do
    # Re-register builtins after (re)start: registrations live in this
    # process's state, so a crash wiped them and they were only restored
    # at app boot. Done via a post-init message + Task so the registration
    # calls don't deadlock against init.
    send(self(), :register_builtins)
    {:ok, %{hooks: %{}}}
  end

  @impl true
  def handle_info(:register_builtins, state) do
    Task.start(fn ->
      try do
        Traitee.Hooks.Builtin.register_all()
      rescue
        e -> Logger.warning("Builtin hook registration failed: #{Exception.message(e)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:register, hook_point, name, handler}, _from, state) do
    hooks = state.hooks
    existing = Map.get(hooks, hook_point, [])
    # Replace any handler with the same name so repeated registration
    # (e.g. Builtin.register_all at boot AND after a restart) stays
    # idempotent instead of stacking duplicates.
    updated = Enum.reject(existing, fn {n, _} -> n == name end) ++ [{name, handler}]
    {:reply, :ok, %{state | hooks: Map.put(hooks, hook_point, updated)}}
  end

  def handle_call({:unregister, hook_point, name}, _from, state) do
    hooks = state.hooks
    existing = Map.get(hooks, hook_point, [])
    updated = Enum.reject(existing, fn {n, _} -> n == name end)
    {:reply, :ok, %{state | hooks: Map.put(hooks, hook_point, updated)}}
  end

  def handle_call({:fire, hook_point, context}, _from, state) do
    handlers = Map.get(state.hooks, hook_point, [])
    result = run_chain(handlers, context)
    {:reply, result, state}
  end

  def handle_call({:list, hook_point}, _from, state) do
    handlers = Map.get(state.hooks, hook_point, [])
    {:reply, Enum.map(handlers, fn {name, handler} -> {name, handler} end), state}
  end

  @impl true
  def handle_cast({:fire, hook_point, context}, state) do
    handlers = Map.get(state.hooks, hook_point, [])
    Task.start(fn -> run_chain(handlers, context) end)
    {:noreply, state}
  end

  defp run_chain([], context), do: {:ok, context}

  defp run_chain([{name, handler} | rest], context) do
    case handler.(context) do
      {:ok, new_context} ->
        run_chain(rest, new_context)

      {:halt, reason} ->
        {:halt, reason}

      other ->
        Logger.warning("Hook #{inspect(name)} returned unexpected: #{inspect(other)}")
        run_chain(rest, context)
    end
  rescue
    e ->
      Logger.error("Hook #{inspect(name)} crashed: #{Exception.message(e)}")
      run_chain(rest, context)
  catch
    # A handler that throws or exits would otherwise kill the Engine,
    # taking every registered hook down with it.
    kind, reason ->
      Logger.error("Hook #{inspect(name)} #{kind}: #{inspect(reason)}")
      run_chain(rest, context)
  end
end
