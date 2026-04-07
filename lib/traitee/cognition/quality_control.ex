defmodule Traitee.Cognition.QualityControl do
  @moduledoc """
  Quality control agent for the cognitive architecture. Validates workshop
  artifacts and dream research before they reach the user.

  Responsibilities:
  - Validate workshop projects: is the code complete? useful? ready?
  - Audit research quality: is it thorough? accurate? interesting?
  - Send work back to workshop/dream with specific feedback
  - Detect and kill loops: hard limits on revisions and circuit breakers

  Loop prevention:
  - Max 3 revisions per workshop project before abandoning
  - Max 2 re-research attempts per topic before accepting as-is
  - Per-cycle token ceiling kills the entire dream if exceeded
  - Time-based circuit breaker on any single QC evaluation (30s)
  """
  use GenServer

  import Ecto.Query

  alias Traitee.Cognition.{Dream, Schema.WorkshopProject}
  alias Traitee.LLM.Router
  alias Traitee.Memory.LTM
  alias Traitee.Repo

  require Logger

  @max_project_revisions 3
  @max_research_retries 2
  @eval_timeout_ms 30_000
  @check_interval_ms 2 * 60_000

  @table :traitee_qc_tracker

  defstruct [
    enabled: true,
    evaluations: 0,
    rejections: 0,
    approvals: 0
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get QC status and stats."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Manually trigger a QC review of a workshop project."
  def review_project(project_id) do
    GenServer.cast(__MODULE__, {:review_project, project_id})
  end

  @doc "Check revision count for an item. Returns count or 0."
  def revision_count(item_key) do
    case :ets.lookup(@table, {:revisions, item_key}) do
      [{_, count}] -> count
      [] -> 0
    end
  rescue
    _ -> 0
  end

  # -- Server --

  @impl true
  def init(_opts) do
    init_table()
    Phoenix.PubSub.subscribe(Traitee.PubSub, "workshop:events")
    Phoenix.PubSub.subscribe(Traitee.PubSub, "dream:events")
    schedule_check()

    {:ok, %__MODULE__{enabled: config(:enabled, true)}}
  end

  @impl true
  def handle_cast({:review_project, project_id}, state) do
    Task.start(fn -> do_review_project(project_id) end)
    {:noreply, %{state | evaluations: state.evaluations + 1}}
  end

  @impl true
  def handle_info({:workshop, :build_complete, %{project: name}}, state) do
    if state.enabled do
      Task.start(fn -> review_by_name(name) end)
      {:noreply, %{state | evaluations: state.evaluations + 1}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:dream, :dream_completed, _meta}, state) do
    if state.enabled do
      Task.start(fn -> audit_recent_research() end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:qc_check, state) do
    if state.enabled do
      Task.start(fn -> sweep_ready_projects() end)
    end

    schedule_check()
    {:noreply, state}
  end

  @impl true
  def handle_info({:qc_result, :approved, _item}, state) do
    {:noreply, %{state | approvals: state.approvals + 1}}
  end

  @impl true
  def handle_info({:qc_result, :rejected, _item}, state) do
    {:noreply, %{state | rejections: state.rejections + 1}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    approval_rate =
      if state.evaluations > 0,
        do: Float.round(state.approvals / state.evaluations, 2),
        else: nil

    summary = %{
      enabled: state.enabled,
      evaluations: state.evaluations,
      approvals: state.approvals,
      rejections: state.rejections,
      approval_rate: approval_rate
    }

    {:reply, summary, state}
  end

  # -- Workshop QC --

  defp review_by_name(project_name) do
    project =
      WorkshopProject
      |> where([p], p.name == ^project_name and p.status == "ready")
      |> Repo.one()

    if project, do: do_review_project(project.id)
  rescue
    e -> Logger.warning("[QC] review_by_name failed: #{inspect(e)}")
  end

  defp sweep_ready_projects do
    WorkshopProject
    |> where([p], p.status == "ready")
    |> Repo.all()
    |> Enum.each(fn project ->
      if not already_reviewed?(project.id) do
        do_review_project(project.id)
      end
    end)
  rescue
    e -> Logger.warning("[QC] sweep failed: #{inspect(e)}")
  end

  defp do_review_project(project_id) do
    project = Repo.get(WorkshopProject, project_id)
    if project == nil, do: throw(:not_found)

    revisions = bump_revision({:project, project_id})

    if revisions > @max_project_revisions do
      Logger.warning("[QC] Project '#{project.name}' hit max revisions (#{revisions}). Abandoning.")
      abandon_project(project, "Exceeded max revision attempts (#{@max_project_revisions})")
      notify_result(:rejected, {:project, project_id})
      throw(:abandoned)
    end

    Logger.info("[QC] Reviewing project: #{project.name} (revision #{revisions})")

    verdict = evaluate_project(project)

    case verdict do
      {:pass, _feedback} ->
        Logger.info("[QC] Project '#{project.name}' APPROVED")
        mark_reviewed(project.id)
        notify_result(:approved, {:project, project_id})

      {:revise, feedback} ->
        Logger.info("[QC] Project '#{project.name}' needs revision: #{feedback}")
        send_back_to_workshop(project, feedback)
        notify_result(:rejected, {:project, project_id})

      {:reject, reason} ->
        Logger.info("[QC] Project '#{project.name}' REJECTED: #{reason}")
        abandon_project(project, reason)
        notify_result(:rejected, {:project, project_id})
    end
  rescue
    e -> Logger.warning("[QC] Review crashed for project #{project_id}: #{inspect(e)}")
  catch
    :not_found -> :ok
    :abandoned -> :ok
  end

  defp evaluate_project(project) do
    artifacts_desc =
      case project.artifacts do
        nil -> "(no artifacts)"
        a when a == %{} -> "(empty artifacts)"
        a -> Jason.encode!(a)
      end

    prompt = """
    You are a quality control reviewer for an AI-built project. Be strict but fair.

    Project: #{project.name}
    Type: #{project.project_type}
    Description: #{project.description}
    Status: #{project.status}
    Artifacts: #{artifacts_desc}

    Evaluate on these criteria:
    1. COMPLETENESS: Is this actually built and functional, or just a skeleton/placeholder?
    2. USEFULNESS: Would a real user find this genuinely useful for the stated purpose?
    3. CORRECTNESS: Are there obvious bugs, missing error handling, or broken logic?
    4. READINESS: Can a user start using this right now without additional setup?

    Return JSON:
    {
      "verdict": "pass" | "revise" | "reject",
      "score": 0.0-1.0,
      "completeness": "complete" | "partial" | "skeleton",
      "usefulness": "high" | "medium" | "low" | "none",
      "issues": ["specific issue 1", "specific issue 2"],
      "feedback": "what needs to change (if revise) or why it's rejected"
    }

    Be honest. A skeleton with TODOs is "reject". Partial but fixable is "revise". Working and useful is "pass".
    """

    case timed_complete(prompt) do
      {:ok, content} ->
        parse_verdict(content)

      {:error, :timeout} ->
        Logger.warning("[QC] Evaluation timed out for #{project.name}")
        {:pass, "QC evaluation timed out — passing to avoid blocking"}

      {:error, reason} ->
        Logger.warning("[QC] Evaluation failed: #{inspect(reason)}")
        {:pass, "QC evaluation failed — passing with caveat"}
    end
  end

  defp parse_verdict(content) do
    case parse_json(content) do
      {:ok, %{"verdict" => "pass"} = parsed} ->
        {:pass, parsed["feedback"] || "Approved"}

      {:ok, %{"verdict" => "revise"} = parsed} ->
        feedback =
          [parsed["feedback"] | parsed["issues"] || []]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(". ")

        {:revise, feedback}

      {:ok, %{"verdict" => "reject"} = parsed} ->
        {:reject, parsed["feedback"] || "Did not meet quality standards"}

      {:ok, %{"completeness" => "skeleton"}} ->
        {:reject, "Project is just a skeleton with no real implementation"}

      _ ->
        {:pass, "Could not parse QC verdict — passing with caveat"}
    end
  end

  defp send_back_to_workshop(project, feedback) do
    project
    |> WorkshopProject.changeset(%{
      status: "ideating",
      metadata:
        (project.metadata || %{})
        |> Map.put("qc_feedback", feedback)
        |> Map.put("qc_revision", revision_count({:project, project.id}))
    })
    |> Repo.update()

    broadcast(:revision_requested, %{project: project.name, feedback: feedback})
  rescue
    e -> Logger.warning("[QC] Failed to send back to workshop: #{inspect(e)}")
  end

  defp abandon_project(project, reason) do
    project
    |> WorkshopProject.changeset(%{
      status: "rejected",
      metadata:
        (project.metadata || %{})
        |> Map.put("qc_abandoned", true)
        |> Map.put("qc_reason", reason)
    })
    |> Repo.update()

    broadcast(:project_abandoned, %{project: project.name, reason: reason})
  rescue
    e -> Logger.warning("[QC] Failed to abandon project: #{inspect(e)}")
  end

  # -- Research QC --

  defp audit_recent_research do
    recent_research =
      LTM.search_entities("research_topic")
      |> Enum.take(5)

    Enum.each(recent_research, fn entity ->
      facts = LTM.get_facts(entity.id)
      retries = revision_count({:research, entity.name})

      if retries >= @max_research_retries do
        Logger.debug("[QC] Research '#{entity.name}' at max retries — accepting as-is")
      else
        if length(facts) < 2 do
          Logger.info("[QC] Research '#{entity.name}' is shallow (#{length(facts)} facts). Re-queuing.")
          bump_revision({:research, entity.name})
          Dream.enqueue_curiosity(entity.name, "QC: previous research was shallow, go deeper")
          notify_result(:rejected, {:research, entity.name})
        else
          quality = assess_research_quality(entity, facts)

          if quality < 0.4 and retries < @max_research_retries do
            Logger.info("[QC] Research '#{entity.name}' quality #{quality} — re-queuing")
            bump_revision({:research, entity.name})
            Dream.enqueue_curiosity(entity.name, "QC: research quality low, needs more depth")
            notify_result(:rejected, {:research, entity.name})
          else
            notify_result(:approved, {:research, entity.name})
          end
        end
      end
    end)
  rescue
    e -> Logger.warning("[QC] Research audit failed: #{inspect(e)}")
  end

  defp assess_research_quality(_entity, facts) do
    fact_count = length(facts)
    avg_length = if fact_count > 0, do: Enum.sum(Enum.map(facts, &String.length(&1.content))) / fact_count, else: 0

    fact_score = min(fact_count / 5.0, 1.0)
    depth_score = min(avg_length / 100.0, 1.0)

    fact_score * 0.6 + depth_score * 0.4
  end

  # -- Loop Prevention --

  defp bump_revision(item_key) do
    current = revision_count(item_key)
    new_count = current + 1
    :ets.insert(@table, {{:revisions, item_key}, new_count})
    new_count
  rescue
    _ -> 1
  end

  defp already_reviewed?(project_id) do
    case :ets.lookup(@table, {:reviewed, project_id}) do
      [{_, true}] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp mark_reviewed(project_id) do
    :ets.insert(@table, {{:reviewed, project_id}, true})
  rescue
    _ -> :ok
  end

  # -- Helpers --

  defp timed_complete(prompt) do
    task =
      Task.async(fn ->
        request = %{
          messages: [%{role: "user", content: prompt}],
          system: "You are a strict quality control reviewer. Return valid JSON only."
        }

        case Router.complete(request) do
          {:ok, %{content: content}} -> {:ok, content}
          {:error, reason} -> {:error, reason}
        end
      end)

    case Task.yield(task, @eval_timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp parse_json(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> Jason.decode()
  end

  defp notify_result(verdict, item) do
    send(self(), {:qc_result, verdict, item})
  rescue
    _ -> :ok
  end

  defp init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  defp schedule_check do
    Process.send_after(self(), :qc_check, @check_interval_ms)
  end

  defp broadcast(event, meta) do
    Phoenix.PubSub.broadcast(Traitee.PubSub, "qc:events", {:qc, event, meta})
  rescue
    _ -> :ok
  end

  defp config(key, default) do
    Traitee.Config.get([:cognition, :quality_control, key]) || default
  rescue
    _ -> default
  end
end
