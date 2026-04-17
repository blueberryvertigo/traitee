defmodule Traitee.Cognition.UserModel do
  @moduledoc """
  Per-user cognitive model. Tracks interests, expertise, desires, active projects,
  and communication style by processing conversation signals via PubSub.

  Maintains an ETS table for fast reads and persists to SQLite for durability.
  """
  use GenServer

  alias Traitee.Cognition.Interest
  alias Traitee.Repo

  require Logger

  @table :traitee_user_models
  @persist_interval_ms 60_000

  defstruct models: %{}, dirty: MapSet.new(), observation_throttle: %{}

  # One observation per owner per minute is sufficient to keep the interest
  # graph current without pounding the LLM on rapid-fire messages.
  @observe_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the full user model for an owner_id. Returns from ETS for speed."
  def get(owner_id) do
    case :ets.lookup(@table, owner_id) do
      [{^owner_id, model}] -> model
      [] -> default_model(owner_id)
    end
  rescue
    _ -> default_model(owner_id)
  end

  @doc "Get the user's top interests sorted by score."
  def top_interests(owner_id, limit \\ 10) do
    model = get(owner_id)

    model.interests
    |> Map.values()
    |> Enum.sort_by(&Interest.score/1, :desc)
    |> Enum.take(limit)
  end

  @doc "Get trending interests for a user."
  def trending_interests(owner_id) do
    model = get(owner_id)
    model.interests |> Map.values() |> Interest.trending()
  end

  @doc "Get the user's explicit desires."
  def desires(owner_id) do
    model = get(owner_id)
    model.desires
  end

  @doc "Record a conversation turn for interest extraction."
  def observe(owner_id, user_message, context_messages \\ []) do
    GenServer.cast(__MODULE__, {:observe, owner_id, user_message, context_messages})
  end

  @doc "Manually add an interest signal."
  def record_interest(owner_id, topic, attrs \\ %{}) do
    GenServer.cast(__MODULE__, {:record_interest, owner_id, topic, attrs})
  end

  @doc "Get a summary suitable for injection into LLM context."
  def profile_summary(owner_id) do
    model = get(owner_id)
    interests = top_interests(owner_id, 5)

    interest_text =
      interests
      |> Enum.map_join(", ", fn i -> "#{i.topic} (#{i.depth})" end)

    expertise_text =
      model.expertise
      |> Enum.map_join(", ", fn e -> "#{e.domain}: #{e.level}" end)

    desires_text = Enum.join(model.desires, "; ")

    "Interests: #{interest_text}\nExpertise: #{expertise_text}\nDesires: #{desires_text}"
  end

  # -- Server --

  @impl true
  def init(_opts) do
    init_table()
    load_from_db()
    Phoenix.PubSub.subscribe(Traitee.PubSub, "cognition:observe")
    schedule_persist()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:observe, owner_id, user_message, context_messages}, state) do
    # Previously this spawned an unbounded `Task.start` per inbound message —
    # a chatty user could pin the LLM provider with extraction calls that
    # compete with user-facing traffic. We now:
    #   1. Debounce: skip observation if the last one for this owner
    #      happened within `@observe_interval_ms` — the interest signal is
    #      low-frequency anyway; every message is overkill.
    #   2. Lane-gate: run the extraction via the `:embed` concurrency lane
    #      so it can't exceed the configured ceiling.
    if should_observe?(state, owner_id) do
      state = mark_observed(state, owner_id)

      Task.Supervisor.start_child(
        Traitee.Delegation.TaskSupervisor,
        fn ->
          Traitee.Process.Lanes.with_lane(:embed, 30_000, fn ->
            case Interest.extract(user_message, context_messages) do
              {:ok, signals} ->
                GenServer.cast(__MODULE__, {:merge_signals, owner_id, signals})

              {:error, reason} ->
                Logger.debug("Interest extraction failed: #{inspect(reason)}")
            end
          end)
        end,
        restart: :temporary
      )

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:merge_signals, owner_id, signals}, state) do
    model = get(owner_id)

    updated_interests = Interest.merge_signals(model.interests, signals)
    updated_expertise = merge_expertise(model.expertise, signals["expertise_signals"] || [])
    updated_desires = merge_desires(model.desires, signals["desires"] || [])
    updated_projects = merge_projects(model.active_projects, signals["active_projects"] || [])

    updated_style =
      case signals["style_notes"] do
        nil -> model.style
        notes -> Map.merge(model.style, atomize_keys(notes))
      end

    updated_model = %{
      model
      | interests: updated_interests,
        expertise: updated_expertise,
        desires: updated_desires,
        active_projects: updated_projects,
        style: updated_style,
        last_updated: DateTime.utc_now()
    }

    :ets.insert(@table, {owner_id, updated_model})
    dirty = MapSet.put(state.dirty, owner_id)

    {:noreply, %{state | dirty: dirty}}
  end

  @impl true
  def handle_cast({:record_interest, owner_id, topic, attrs}, state) do
    model = get(owner_id)

    signal = %{
      "interests" => [
        %{
          "topic" => topic,
          "enthusiasm" => attrs[:enthusiasm] || 0.7,
          "depth" => attrs[:depth] || "moderate"
        }
      ]
    }

    updated = Interest.merge_signals(model.interests, signal)
    updated_model = %{model | interests: updated, last_updated: DateTime.utc_now()}

    :ets.insert(@table, {owner_id, updated_model})
    dirty = MapSet.put(state.dirty, owner_id)

    {:noreply, %{state | dirty: dirty}}
  end

  @impl true
  def handle_info(:persist, state) do
    persist_dirty(state.dirty)
    schedule_persist()
    {:noreply, %{state | dirty: MapSet.new()}}
  end

  @impl true
  def handle_info({:cognition_observe, owner_id, message, context}, state) do
    handle_cast({:observe, owner_id, message, context}, state)
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp should_observe?(state, owner_id) do
    last = Map.get(state.observation_throttle || %{}, owner_id, 0)
    now = System.monotonic_time(:millisecond)
    now - last > @observe_interval_ms
  end

  defp mark_observed(state, owner_id) do
    now = System.monotonic_time(:millisecond)
    throttle = Map.put(state.observation_throttle || %{}, owner_id, now)
    %{state | observation_throttle: throttle}
  end

  defp init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp default_model(owner_id) do
    %{
      owner_id: owner_id,
      interests: %{},
      expertise: [],
      desires: [],
      active_projects: [],
      style: %{formality: :neutral, detail_preference: :moderate},
      last_updated: nil
    }
  end

  defp merge_expertise(existing, new_signals) do
    new_domains =
      Enum.map(new_signals, fn s ->
        %{domain: s["domain"], level: s["level"], evidence: s["evidence"]}
      end)

    merged =
      (existing ++ new_domains)
      |> Enum.group_by(& &1.domain)
      |> Enum.map(fn {_domain, entries} -> List.last(entries) end)

    merged
  end

  defp merge_desires(existing, new_desires) do
    (existing ++ new_desires)
    |> Enum.uniq()
    |> Enum.take(50)
  end

  defp merge_projects(existing, new_projects) do
    (new_projects ++ existing)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        {String.to_existing_atom(k), v}

      {k, v} ->
        {k, v}
    end)
  rescue
    _ -> map
  end

  defp schedule_persist do
    Process.send_after(self(), :persist, @persist_interval_ms)
  end

  defp persist_dirty(dirty_set) do
    Enum.each(dirty_set, fn owner_id ->
      model = get(owner_id)
      persist_user_model(owner_id, model)
    end)
  rescue
    e -> Logger.warning("UserModel persist failed: #{inspect(e)}")
  end

  defp persist_user_model(owner_id, model) do
    interests =
      model.interests
      |> Map.values()
      |> Enum.each(fn interest ->
        attrs = %{
          owner_id: owner_id,
          topic: interest.topic,
          enthusiasm_score: interest.enthusiasm,
          frequency: interest.frequency,
          depth: to_string(interest.depth),
          first_seen: interest.first_seen,
          last_seen: interest.last_seen,
          trend: to_string(interest.trend),
          evidence: %{},
          metadata: %{}
        }

        Repo.insert!(
          Traitee.Cognition.Schema.UserInterest.changeset(
            %Traitee.Cognition.Schema.UserInterest{},
            attrs
          ),
          on_conflict: {:replace, [:enthusiasm_score, :frequency, :depth, :last_seen, :trend]},
          conflict_target: [:owner_id, :topic]
        )
      end)

    interests
  rescue
    e -> Logger.debug("Interest persist skipped (table may not exist yet): #{inspect(e)}")
  end

  defp load_from_db do
    try do
      Traitee.Cognition.Schema.UserInterest
      |> Repo.all()
      |> Enum.group_by(& &1.owner_id)
      |> Enum.each(fn {owner_id, records} ->
        interests =
          Map.new(records, fn r ->
            {r.topic,
             %{
               topic: r.topic,
               enthusiasm: r.enthusiasm_score || 0.5,
               depth: r.depth || "shallow",
               frequency: r.frequency || 1,
               first_seen: r.first_seen || r.inserted_at,
               last_seen: r.last_seen || r.inserted_at,
               trend: String.to_existing_atom(r.trend || "stable")
             }}
          end)

        model = %{default_model(owner_id) | interests: interests}
        :ets.insert(@table, {owner_id, model})
      end)
    rescue
      _ -> :ok
    end
  end
end
