defmodule Traitee.Cognition.Dream do
  @moduledoc """
  Background cognitive process that activates when the agent is idle.

  Runs four dream cycles:
  1. Memory Consolidation -- dedup, connect orphans, score importance
  2. Auto-Research -- investigate topics the agent is curious about
  3. Ideation -- generate project ideas from user interests
  4. Self-Reflection -- analyze performance, identify improvement opportunities

  Uses Process.Lanes with a dedicated :dream lane to avoid competing
  with foreground conversations.
  """
  use GenServer

  alias Traitee.ActivityLog
  alias Traitee.Cognition.{Interest, UserModel}
  alias Traitee.LLM.Router
  alias Traitee.Memory.LTM
  alias Traitee.Process.Lanes
  alias Traitee.Session

  require Logger

  @idle_check_ms 60_000
  @max_tokens_per_cycle 50_000

  defstruct [
    :last_dream,
    :dream_interval,
    :token_budget,
    tokens_used: 0,
    curiosity_queue: :queue.new(),
    dream_log: [],
    enabled: true
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a topic the agent is curious about for background research."
  def enqueue_curiosity(topic, context \\ nil) do
    GenServer.cast(__MODULE__, {:curiosity, topic, context})
  end

  @doc "Force a dream cycle immediately (for testing or manual trigger)."
  def dream_now do
    GenServer.cast(__MODULE__, :dream_now)
  end

  @doc "Get the current dream state summary."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    interval = config(:dream_interval_minutes, 120) * 60_000
    budget = config(:dream_token_budget, @max_tokens_per_cycle)

    schedule_idle_check()
    Phoenix.PubSub.subscribe(Traitee.PubSub, "session:events")

    state = %__MODULE__{
      dream_interval: interval,
      token_budget: budget,
      enabled: config(:enabled, true)
    }

    {:ok, state}
  end

  @curiosity_threshold 5

  @impl true
  def handle_cast({:curiosity, topic, context}, state) do
    item = %{topic: topic, context: context, queued_at: DateTime.utc_now()}
    queue = :queue.in(item, state.curiosity_queue)
    state = %{state | curiosity_queue: queue}

    if :queue.len(queue) >= @curiosity_threshold and no_active_sessions?() and state.enabled do
      Logger.info("[Dream] Curiosity threshold reached (#{:queue.len(queue)} topics) — triggering dream")
      Process.send_after(self(), :curiosity_dream, 5_000)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:dream_now, state) do
    state = run_dream_cycle(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:idle_check, state) do
    state =
      if should_dream?(state) do
        run_dream_cycle(state)
      else
        state
      end

    schedule_idle_check()
    {:noreply, state}
  end

  @impl true
  def handle_info({:session_ended, _session_id}, state) do
    if state.enabled and no_active_sessions?() and :queue.len(state.curiosity_queue) > 0 do
      Logger.info("[Dream] Last session ended with #{:queue.len(state.curiosity_queue)} curiosity items — dreaming soon")
      Process.send_after(self(), :post_session_dream, 30_000)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:post_session_dream, state) do
    state =
      if no_active_sessions?() and state.enabled do
        run_dream_cycle(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:curiosity_dream, state) do
    state =
      if no_active_sessions?() and state.enabled and :queue.len(state.curiosity_queue) > 0 do
        run_dream_cycle(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    summary = %{
      enabled: state.enabled,
      last_dream: state.last_dream,
      curiosity_queue_size: :queue.len(state.curiosity_queue),
      tokens_used_last_cycle: state.tokens_used,
      recent_dreams: Enum.take(state.dream_log, 5)
    }

    {:reply, summary, state}
  end

  # -- Dream Cycle --

  defp should_dream?(state) do
    state.enabled and
      no_active_sessions?() and
      dream_interval_elapsed?(state)
  end

  defp no_active_sessions? do
    Session.list_active() == []
  end

  defp dream_interval_elapsed?(%{last_dream: nil}), do: true

  defp dream_interval_elapsed?(%{last_dream: last, dream_interval: interval}) do
    DateTime.diff(DateTime.utc_now(), last, :millisecond) >= interval
  end

  defp run_dream_cycle(state) do
    Logger.info("[Dream] Starting dream cycle")
    broadcast(:dream_started, %{})
    started_at = DateTime.utc_now()

    state = %{state | tokens_used: 0}

    state =
      with_lane(:dream, fn ->
        state
        |> cycle_consolidation()
        |> cycle_research()
        |> cycle_ideation()
        |> cycle_reflection()
      end) || state

    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :second)

    log_entry = %{
      started_at: started_at,
      elapsed_seconds: elapsed,
      tokens_used: state.tokens_used
    }

    Logger.info("[Dream] Cycle complete (#{elapsed}s, #{state.tokens_used} tokens)")
    broadcast(:dream_completed, log_entry)

    %{state | last_dream: DateTime.utc_now(), dream_log: [log_entry | Enum.take(state.dream_log, 19)]}
  end

  # -- Cycle 1: Memory Consolidation --

  defp cycle_consolidation(state) do
    if budget_remaining?(state) do
      Logger.debug("[Dream] Consolidation: scanning for duplicates and orphans")

      consolidate_duplicate_entities()
      connect_orphaned_entities(state)
      score_entity_importance()

      state
    else
      state
    end
  rescue
    e ->
      Logger.warning("[Dream] Consolidation failed: #{inspect(e)}")
      state
  end

  defp consolidate_duplicate_entities do
    entities = LTM.all_entities()

    entities
    |> Enum.group_by(fn e -> String.downcase(e.name) end)
    |> Enum.filter(fn {_name, group} -> length(group) > 1 end)
    |> Enum.each(fn {_name, group} ->
      [primary | duplicates] = Enum.sort_by(group, & &1.mention_count, :desc)

      Enum.each(duplicates, fn dup ->
        merge_entity_into(dup, primary)
      end)
    end)
  rescue
    _ -> :ok
  end

  defp merge_entity_into(source, target) do
    source_facts = LTM.get_facts(source.id)

    Enum.each(source_facts, fn fact ->
      LTM.add_fact(target.id, fact.content, fact.fact_type)
    end)

    LTM.upsert_entity(target.name, target.entity_type, source.description || target.description)
  rescue
    _ -> :ok
  end

  defp connect_orphaned_entities(state) do
    entities = LTM.all_entities()

    orphans =
      entities
      |> Enum.filter(fn e ->
        LTM.get_relations(e.id) == [] and (e.mention_count || 0) <= 1
      end)
      |> Enum.take(5)

    if orphans != [] and budget_remaining?(state) do
      names = Enum.map(orphans, & &1.name) |> Enum.join(", ")

      all_names =
        entities
        |> Enum.reject(fn e -> e.id in Enum.map(orphans, & &1.id) end)
        |> Enum.map(& &1.name)
        |> Enum.take(50)
        |> Enum.join(", ")

      prompt = """
      Given these orphaned knowledge graph entities: #{names}
      And these existing entities: #{all_names}

      Identify any relationships between orphaned entities and existing entities.
      Return JSON array:
      [{"source": "entity_name", "target": "entity_name", "relation_type": "type", "description": "why"}]

      Only include relationships you are confident about. Return [] if none.
      """

      case complete_with_budget(prompt, state) do
        {:ok, content, _tokens} ->
          parse_and_store_relations(content)

        _ ->
          :ok
      end
    end
  end

  defp score_entity_importance do
    LTM.all_entities()
    |> Enum.each(fn entity ->
      relations = LTM.get_relations(entity.id)
      facts = LTM.get_facts(entity.id)
      relation_density = length(relations) / max(1.0, 10.0)
      fact_density = length(facts) / max(1.0, 20.0)
      mention_weight = (entity.mention_count || 1) / 10.0

      _importance = min(mention_weight * 0.4 + relation_density * 0.3 + fact_density * 0.3, 1.0)
      :ok
    end)
  rescue
    _ -> :ok
  end

  # -- Cycle 2: Auto-Research --

  defp cycle_research(state) do
    if budget_remaining?(state) do
      Logger.debug("[Dream] Research: processing curiosity queue and interest gaps")

      state =
        process_curiosity_queue(state)

      state =
        research_interest_gaps(state)

      state
    else
      state
    end
  rescue
    e ->
      Logger.warning("[Dream] Research failed: #{inspect(e)}")
      state
  end

  defp process_curiosity_queue(state) do
    case :queue.out(state.curiosity_queue) do
      {{:value, item}, rest} ->
        state = %{state | curiosity_queue: rest}

        if budget_remaining?(state) do
          research_topic(item.topic, state)
        else
          state
        end

      {:empty, _} ->
        state
    end
  end

  defp research_interest_gaps(state) do
    owner_id = resolve_owner_id()
    if owner_id == nil, do: throw(:skip)

    trending = UserModel.trending_interests(owner_id)

    trending
    |> Enum.take(3)
    |> Enum.reduce(state, fn interest, acc ->
      if budget_remaining?(acc) do
        existing_facts = LTM.search_facts(interest.topic)

        if length(existing_facts) < 3 do
          research_topic(interest.topic, acc)
        else
          acc
        end
      else
        acc
      end
    end)
  catch
    :skip -> state
  end

  defp research_topic(topic, state) do
    Logger.debug("[Dream] Researching: #{topic}")

    prompt = """
    Research the topic: "#{topic}"

    Provide a comprehensive but concise summary covering:
    1. Current state and latest developments
    2. Key concepts and terminology
    3. Important resources or tools
    4. Practical applications

    Return JSON:
    {
      "summary": "2-3 paragraph overview",
      "key_facts": ["fact1", "fact2", ...],
      "entities": [{"name": "...", "type": "concept|tool|person|org", "description": "..."}],
      "relations": [{"source": "...", "target": "...", "relation_type": "..."}]
    }
    """

    case complete_with_budget(prompt, state) do
      {:ok, content, tokens} ->
        state = %{state | tokens_used: state.tokens_used + tokens}
        store_research_results(topic, content)
        state

      {:error, _} ->
        state
    end
  end

  defp store_research_results(topic, content) do
    case parse_json(content) do
      {:ok, parsed} ->
        {:ok, entity} = LTM.upsert_entity(topic, "research_topic", parsed["summary"])

        (parsed["key_facts"] || [])
        |> Enum.each(fn fact ->
          LTM.add_fact(entity.id, fact, "researched")
        end)

        (parsed["entities"] || [])
        |> Enum.each(fn e ->
          {:ok, sub} = LTM.upsert_entity(e["name"], e["type"] || "concept", e["description"])
          LTM.add_relation(entity.id, sub.id, "contains")
        end)

        (parsed["relations"] || [])
        |> Enum.each(fn r ->
          source = LTM.get_entity_by_name(r["source"], "concept") || LTM.get_entity_by_name(r["source"], "research_topic")
          target = LTM.get_entity_by_name(r["target"], "concept") || LTM.get_entity_by_name(r["target"], "research_topic")

          if source && target do
            LTM.add_relation(source.id, target.id, r["relation_type"] || "related_to")
          end
        end)

      _ ->
        LTM.upsert_entity(topic, "research_topic", content)
    end
  rescue
    e -> Logger.warning("[Dream] Store research failed: #{inspect(e)}")
  end

  # -- Cycle 3: Ideation --

  defp cycle_ideation(state) do
    if budget_remaining?(state) do
      Logger.debug("[Dream] Ideation: generating project ideas")

      owner_id = resolve_owner_id()
      if owner_id == nil, do: throw(:skip)

      profile = %{
        interests: UserModel.get(owner_id).interests,
        expertise: UserModel.get(owner_id).expertise,
        desires: UserModel.desires(owner_id),
        existing_tools: list_existing_tools()
      }

      case Interest.suggest_projects(profile) do
        {:ok, projects} ->
          Enum.each(projects, fn project ->
            store_project_idea(project, owner_id)
          end)

          broadcast(:ideation_complete, %{project_count: length(projects)})

        {:error, reason} ->
          Logger.debug("[Dream] Ideation failed: #{inspect(reason)}")
      end

      state
    else
      state
    end
  rescue
    e ->
      Logger.warning("[Dream] Ideation failed: #{inspect(e)}")
      state
  catch
    :skip -> state
  end

  defp store_project_idea(project, owner_id) do
    import Ecto.Query

    existing =
      Traitee.Cognition.Schema.WorkshopProject
      |> where([p], p.name == ^project["name"] and p.owner_id == ^owner_id)
      |> Traitee.Repo.one()

    if existing == nil do
      attrs = %{
        name: project["name"],
        description: project["description"],
        project_type: project["type"] || "tool",
        status: "ideating",
        interest_source: project["interest_source"],
        owner_id: owner_id,
        metadata: %{complexity: project["complexity"]}
      }

      Traitee.Cognition.Schema.WorkshopProject.changeset(
        %Traitee.Cognition.Schema.WorkshopProject{},
        attrs
      )
      |> Traitee.Repo.insert()
    end
  rescue
    e -> Logger.debug("[Dream] Store idea failed: #{inspect(e)}")
  end

  # -- Cycle 4: Self-Reflection --

  defp cycle_reflection(state) do
    if budget_remaining?(state) do
      Logger.debug("[Dream] Reflection: analyzing recent performance")

      owner_id = resolve_owner_id()
      if owner_id == nil, do: throw(:skip)

      recent_activity = gather_recent_activity()

      if recent_activity != "" do
        prompt = """
        Analyze these recent AI assistant activity logs and identify patterns:

        #{recent_activity}

        Return JSON:
        {
          "strengths": ["things that went well"],
          "weaknesses": ["things that could improve"],
          "patterns": ["recurring patterns noticed"],
          "suggestions": ["specific actionable improvements"]
        }
        """

        case complete_with_budget(prompt, state) do
          {:ok, content, tokens} ->
            state = %{state | tokens_used: state.tokens_used + tokens}
            store_reflection(content)
            state

          _ ->
            state
        end
      else
        state
      end
    else
      state
    end
  rescue
    e ->
      Logger.warning("[Dream] Reflection failed: #{inspect(e)}")
      state
  catch
    :skip -> state
  end

  defp store_reflection(content) do
    case parse_json(content) do
      {:ok, parsed} ->
        {:ok, entity} = LTM.upsert_entity("self_reflection", "metacognition")

        suggestions = parsed["suggestions"] || []

        Enum.each(suggestions, fn suggestion ->
          LTM.add_fact(entity.id, suggestion, "self_improvement")
        end)

        (parsed["weaknesses"] || [])
        |> Enum.each(fn w ->
          LTM.add_fact(entity.id, "Weakness: #{w}", "self_assessment")
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # -- Helpers --

  defp complete_with_budget(prompt, state) do
    if state.tokens_used >= state.token_budget do
      {:error, :budget_exhausted}
    else
      request = %{
        messages: [%{role: "user", content: prompt}],
        system: "You are a precise research and analysis agent. Return valid JSON only."
      }

      case Router.complete(request) do
        {:ok, %{content: content, usage: usage}} ->
          tokens = (usage && usage[:total_tokens]) || estimate_tokens(content)
          {:ok, content, tokens}

        {:ok, %{content: content}} ->
          {:ok, content, estimate_tokens(content)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp estimate_tokens(text) when is_binary(text), do: ceil(String.length(text) / 4)
  defp estimate_tokens(_), do: 0

  defp budget_remaining?(%{tokens_used: used, token_budget: budget}), do: used < budget

  defp parse_json(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> Jason.decode()
  end

  defp parse_and_store_relations(content) do
    case parse_json(content) do
      {:ok, relations} when is_list(relations) ->
        Enum.each(relations, fn r ->
          source = LTM.search_entities(r["source"]) |> List.first()
          target = LTM.search_entities(r["target"]) |> List.first()

          if source && target do
            LTM.add_relation(source.id, target.id, r["relation_type"] || "related_to", r["description"])
          end
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp gather_recent_activity do
    sessions = Session.list_active()

    sessions
    |> Enum.flat_map(fn {sid, _pid} ->
      ActivityLog.recent(sid, 20)
    end)
    |> Enum.take(50)
    |> Enum.map_join("\n", fn entry ->
      "#{entry.type}: #{inspect(Map.drop(entry, [:type, :session_id]))}"
    end)
  rescue
    _ -> ""
  end

  defp resolve_owner_id do
    Traitee.Config.get([:security, :owner_id])
  end

  defp list_existing_tools do
    Traitee.Tools.Registry.tool_schemas()
    |> Enum.map(fn tool ->
      func = tool["function"] || tool[:function] || %{}
      func["name"] || func[:name]
    end)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp with_lane(lane, fun) do
    case Lanes.acquire(lane, 5_000) do
      :ok ->
        try do
          fun.()
        after
          Lanes.release(lane)
        end

      {:error, _} ->
        Logger.debug("[Dream] Could not acquire #{lane} lane, skipping")
        nil
    end
  rescue
    _ -> nil
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_check_ms)
  end

  defp broadcast(event, meta) do
    Phoenix.PubSub.broadcast(
      Traitee.PubSub,
      "dream:events",
      {:dream, event, meta}
    )
  rescue
    _ -> :ok
  end

  defp config(key, default) do
    Traitee.Config.get([:cognition, key]) || default
  rescue
    _ -> default
  end
end
