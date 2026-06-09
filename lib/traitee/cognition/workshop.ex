defmodule Traitee.Cognition.Workshop do
  @moduledoc """
  Autonomous project builder. Takes ideas from the Dream State and builds them:
  dynamic tools, skills, code projects, and research briefs.

  Uses the existing tool infrastructure (file, bash, Tools.Registry, Skills.Loader)
  through LLM-driven build loops.
  """
  use GenServer

  import Ecto.Query

  alias Traitee.Cognition.Schema.WorkshopProject
  alias Traitee.LLM.Router
  alias Traitee.Memory.LTM
  alias Traitee.Repo
  alias Traitee.Skills.Loader, as: SkillsLoader
  alias Traitee.Tools.Registry, as: ToolRegistry

  require Logger

  @build_check_ms 5 * 60_000
  @workshop_dir "workshop"
  @max_build_attempts 3
  @retry_cooldown_seconds 3600

  defstruct [
    :current_project,
    build_queue: :queue.new(),
    completed: [],
    token_budget: 100_000,
    enabled: true
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue a project for building."
  def enqueue(project_id) do
    GenServer.cast(__MODULE__, {:enqueue, project_id})
  end

  @doc "Get projects ready for presentation to the user."
  def pending_presentations(owner_id) do
    WorkshopProject
    |> where([p], p.owner_id == ^owner_id and p.status == "ready")
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Mark a project as presented."
  def mark_presented(project_id) do
    case Repo.get(WorkshopProject, project_id) do
      nil -> :ok
      project -> project |> WorkshopProject.changeset(%{status: "presented"}) |> Repo.update()
    end
  rescue
    _ -> :ok
  end

  @doc "User accepted/rejected a project."
  def user_feedback(project_id, :accept) do
    update_status(project_id, "accepted")
  end

  def user_feedback(project_id, :reject) do
    update_status(project_id, "rejected")
  end

  @doc "Get workshop status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- Server --

  @impl true
  def init(_opts) do
    budget = config(:workshop_token_budget, 100_000)
    enabled = config(:enabled, true)
    autonomy = config(:autonomy_level, "build")

    schedule_build_check()

    {:ok,
     %__MODULE__{
       token_budget: budget,
       enabled: enabled and autonomy == "build"
     }}
  end

  @impl true
  def handle_cast({:enqueue, project_id}, state) do
    queue = :queue.in(project_id, state.build_queue)
    {:noreply, %{state | build_queue: queue}}
  end

  @impl true
  def handle_cast({:build_done, project_id}, state) do
    # Previously `completed` grew unbounded. Keep a rolling window — the
    # DB is the source of truth for completed projects; this list is just
    # debug-ish state for :status queries.
    completed = [project_id | state.completed] |> Enum.take(100)
    {:noreply, %{state | current_project: nil, completed: completed}}
  end

  @impl true
  def handle_info(:build_check, state) do
    state =
      if state.enabled and state.current_project == nil do
        maybe_pick_and_build(state)
      else
        state
      end

    schedule_build_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    summary = %{
      enabled: state.enabled,
      current_project: state.current_project,
      queue_size: :queue.len(state.build_queue),
      completed_count: length(state.completed)
    }

    {:reply, summary, state}
  end

  # -- Build Pipeline --

  defp maybe_pick_and_build(state) do
    case :queue.out(state.build_queue) do
      {{:value, project_id}, rest} ->
        state = %{state | build_queue: rest, current_project: project_id}
        Task.start(fn -> build_project(project_id) end)
        state

      {:empty, _} ->
        pick_from_db(state)
    end
  end

  defp pick_from_db(state) do
    candidates =
      WorkshopProject
      |> where([p], p.status == "ideating")
      |> order_by([p], asc: p.inserted_at)
      |> limit(5)
      |> Repo.all()

    case Enum.find(candidates, fn project -> not recently_failed?(project) end) do
      nil ->
        state

      project ->
        state = %{state | current_project: project.id}
        Task.start(fn -> build_project(project.id) end)
        state
    end
  rescue
    _ -> state
  end

  defp recently_failed?(project) do
    with %{"last_failed_at" => ts} <- project.metadata,
         {:ok, failed_at, _offset} <- DateTime.from_iso8601(ts) do
      DateTime.diff(DateTime.utc_now(), failed_at, :second) < @retry_cooldown_seconds
    else
      _ -> false
    end
  end

  defp build_project(project_id) do
    do_build_project(project_id)
  rescue
    e ->
      Logger.warning("[Workshop] Build crashed: #{inspect(e)}")

      case Repo.get(WorkshopProject, project_id) do
        nil -> :ok
        project -> handle_build_failure(project, {:crashed, inspect(e)})
      end
  catch
    :not_found -> :ok
  after
    # ALWAYS release the current_project lock, even on crash. Previously a
    # crash between Repo.update and this cast left the Workshop wedged —
    # current_project stuck non-nil forever, so no new builds ever ran.
    GenServer.cast(__MODULE__, {:build_done, project_id})
  end

  defp do_build_project(project_id) do
    project = Repo.get(WorkshopProject, project_id)
    if project == nil, do: throw(:not_found)

    # Idempotency: refuse to re-drive a project that has moved past the
    # build phase. Without this guard, re-enqueueing (e.g. after a crash)
    # would rebuild an already-ready / accepted project.
    unless project.status in ["ideating", "researching", "building"] do
      Logger.debug("[Workshop] Skipping #{project.name}: status=#{project.status}")
      throw(:not_found)
    end

    Logger.info("[Workshop] Building project: #{project.name} (#{project.project_type})")
    update_status(project_id, "researching")
    broadcast(:build_started, %{project: project.name})

    budget = config(:workshop_token_budget, 100_000)

    result =
      with {:ok, research, tokens} <- research_phase(project, 0, budget),
           {:ok, design, type, tokens} <- design_phase(project, research, tokens, budget),
           {:ok, artifacts} <- build_phase(project, design, type),
           {:ok, artifacts} <- validate_phase(artifacts) do
        {:ok, artifacts, tokens}
      end

    case result do
      {:ok, artifacts, tokens} ->
        project
        |> WorkshopProject.changeset(%{
          status: "ready",
          artifacts: artifacts,
          token_cost: (project.token_cost || 0) + tokens
        })
        |> Repo.update()

        # Single review trigger: we broadcast the build_complete event on
        # which the QC GenServer subscribes. Do NOT also call
        # `QualityControl.review_project/1` synchronously — that created a
        # double-review race where two concurrent Repo.updates fought over
        # the same row with duplicate LLM cost.
        Logger.info("[Workshop] Project built, awaiting QC: #{project.name}")
        broadcast(:build_complete, %{project: project.name, artifacts: artifacts})

      {:error, reason} ->
        Logger.warning("[Workshop] Build failed for #{project.name}: #{inspect(reason)}")
        handle_build_failure(project, reason)
    end
  end

  # Record a failed attempt. After @max_build_attempts the project is
  # permanently rejected so the build loop never re-picks it (previously
  # a failing project reset to "ideating" and retried forever every 5 min).
  defp handle_build_failure(project, reason) do
    attempts = build_attempts(project) + 1
    status = if attempts >= @max_build_attempts, do: "rejected", else: "ideating"

    metadata =
      (project.metadata || %{})
      |> Map.put("last_error", inspect(reason))
      |> Map.put("build_attempts", attempts)
      |> Map.put("last_failed_at", DateTime.to_iso8601(DateTime.utc_now()))

    project
    |> WorkshopProject.changeset(%{status: status, metadata: metadata})
    |> Repo.update()

    broadcast(:build_failed, %{project: project.name, reason: inspect(reason)})
  rescue
    e ->
      Logger.warning("[Workshop] Failed to record build failure: #{inspect(e)}")
      :ok
  end

  defp build_attempts(project) do
    case project.metadata do
      %{"build_attempts" => n} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp research_phase(project, tokens, budget) do
    prompt = """
    I need to build a #{project.project_type} called "#{project.name}".
    Description: #{project.description}

    Research what's needed:
    1. What existing tools, libraries, or APIs could help?
    2. What's the best approach for implementation?
    3. What are the key components?

    Return JSON:
    {
      "approach": "recommended implementation approach",
      "components": ["component1", "component2"],
      "dependencies": ["any external deps needed"],
      "estimated_complexity": "simple|moderate|complex"
    }
    """

    case complete_with_budget(prompt, tokens, budget) do
      {:ok, content, used} ->
        research =
          case parse_json(content) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        {:ok, research, tokens + used}

      {:error, :budget_exhausted} ->
        {:error, :token_budget_exceeded}

      {:error, _} ->
        {:ok, %{}, tokens}
    end
  end

  defp design_phase(project, research, tokens, budget) do
    update_status(project.id, "building")

    type =
      case project.project_type do
        "tool" -> :tool
        "skill" -> :skill
        "research" -> :research
        _ -> :code
      end

    prompt = design_prompt(type, project, research)

    case complete_with_budget(prompt, tokens, budget) do
      {:ok, content, used} ->
        case parse_json(content) do
          {:ok, design} -> {:ok, design, type, tokens + used}
          {:error, reason} -> {:error, {:design_parse_failed, inspect(reason)}}
        end

      {:error, :budget_exhausted} ->
        {:error, :token_budget_exceeded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp design_prompt(:tool, project, research) do
    """
    Design a dynamic tool for Traitee (Elixir AI assistant).
    Tool name: #{project.name}
    Purpose: #{project.description}
    Research: #{Jason.encode!(research)}

    The tool will be registered as a bash-template dynamic tool.
    Design the tool spec:

    Return JSON:
    {
      "name": "tool_name",
      "description": "what it does",
      "parameters": {
        "type": "object",
        "properties": {"param1": {"type": "string", "description": "..."}},
        "required": ["param1"]
      },
      "executor_template": "bash command with ${param1} interpolation",
      "setup_commands": ["any setup needed, e.g. pip install ..."]
    }
    """
  end

  defp design_prompt(:skill, project, research) do
    """
    Design a skill for Traitee (Elixir AI assistant).
    Skill name: #{project.name}
    Purpose: #{project.description}
    Research: #{Jason.encode!(research)}

    A skill is a SKILL.md file with YAML frontmatter and a body containing instructions.
    Design the skill:

    Return JSON:
    {
      "name": "skill-name",
      "frontmatter": {
        "description": "one line description",
        "triggers": ["keyword1", "keyword2"],
        "enabled": true
      },
      "body": "Full skill instructions in markdown..."
    }
    """
  end

  defp design_prompt(:code, project, research) do
    """
    Design a code project for the user.
    Project: #{project.name}
    Purpose: #{project.description}
    Research: #{Jason.encode!(research)}

    Design the file structure and content:
    Return JSON:
    {
      "files": [
        {"path": "relative/path/file.ext", "content": "file contents..."},
        ...
      ],
      "readme": "README content explaining the project",
      "run_command": "how to run/use this project"
    }
    """
  end

  defp design_prompt(:research, project, _research) do
    """
    Create a comprehensive research brief on: #{project.description}

    Return JSON:
    {
      "title": "#{project.name}",
      "sections": [
        {"heading": "...", "content": "..."},
        ...
      ],
      "key_findings": ["finding1", "finding2"],
      "recommendations": ["rec1", "rec2"]
    }
    """
  end

  defp build_phase(project, design, :tool) do
    setup = design["setup_commands"] || []

    Enum.each(setup, fn cmd ->
      safe_execute(cmd)
    end)

    # Atom keys matching the Tools.Registry.register_dynamic contract
    # (:name/:description/:parameters_schema/:executor). String keys used
    # to be merged alongside the atom-key defaults, producing tools with
    # empty schemas and a missing executor.
    spec = %{
      name: design["name"] || project.name,
      description: design["description"] || project.description || "",
      parameters_schema: design["parameters"] || %{"type" => "object", "properties" => %{}},
      executor: {:bash, design["executor_template"] || "echo 'not implemented'"}
    }

    case ToolRegistry.register_dynamic(spec.name, spec) do
      :ok ->
        {:ok, %{type: "tool", name: spec.name, registered: true}}

      {:error, reason} ->
        {:error, {:tool_registration_failed, reason}}
    end
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_phase(project, design, :skill) do
    name = design["name"] || project.name
    frontmatter = design["frontmatter"] || %{}
    body = design["body"] || ""

    case SkillsLoader.create_skill(name, frontmatter, body) do
      {:ok, _} ->
        {:ok, %{type: "skill", name: name, created: true}}

      {:error, reason} ->
        {:error, {:skill_creation_failed, reason}}
    end
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_phase(project, design, :code) do
    case safe_project_dir(project.name) do
      {:ok, workshop_path} ->
        File.mkdir_p!(workshop_path)

        files = design["files"] || []

        written =
          Enum.count(files, fn file ->
            safe_write(workshop_path, file["path"], file["content"] || "") == :ok
          end)

        if design["readme"] do
          File.write!(Path.join(workshop_path, "README.md"), design["readme"])
        end

        {:ok,
         %{
           type: "code",
           path: workshop_path,
           file_count: written,
           run_command: design["run_command"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_phase(project, design, :research) do
    case safe_project_dir(project.name) do
      {:ok, workshop_path} -> build_research_brief(project, design, workshop_path)
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_research_brief(project, design, workshop_path) do
    File.mkdir_p!(workshop_path)

    sections = design["sections"] || []

    content =
      "# #{design["title"] || project.name}\n\n" <>
        Enum.map_join(sections, "\n\n", fn s ->
          "## #{s["heading"]}\n\n#{s["content"]}"
        end) <>
        "\n\n## Key Findings\n\n" <>
        Enum.map_join(design["key_findings"] || [], "\n", &"- #{&1}") <>
        "\n\n## Recommendations\n\n" <>
        Enum.map_join(design["recommendations"] || [], "\n", &"- #{&1}")

    File.write!(Path.join(workshop_path, "BRIEF.md"), content)

    (design["key_findings"] || [])
    |> Enum.each(fn finding ->
      {:ok, entity} = LTM.upsert_entity(project.name, "research")
      LTM.add_fact(entity.id, finding, "research_finding")
    end)

    {:ok, %{type: "research", path: workshop_path}}
  end

  # A tool that fails its smoke execution is a failed build (previously
  # the error was swallowed as `validation: :skipped` and the broken tool
  # shipped as "ready").
  defp validate_phase(%{type: "tool", name: name} = artifacts) do
    case ToolRegistry.execute(name, %{}) do
      {:ok, _} -> {:ok, artifacts}
      {:error, reason} -> {:error, {:validation_failed, inspect(reason)}}
    end
  rescue
    e -> {:error, {:validation_failed, inspect(e)}}
  end

  defp validate_phase(artifacts), do: {:ok, artifacts}

  # -- Helpers --

  # Mirrors Dream.complete_with_budget/2: refuse to spend once the
  # accumulated token count crosses the configured budget.
  defp complete_with_budget(prompt, tokens_used, budget) do
    if tokens_used >= budget do
      {:error, :budget_exhausted}
    else
      request = %{
        messages: [%{role: "user", content: prompt}],
        system:
          "You are an expert software engineer building tools and projects. Return valid JSON only, no explanation."
      }

      case Router.complete(request) do
        {:ok, %{content: content, usage: usage}} ->
          {:ok, content, (usage && usage[:total_tokens]) || estimate_tokens(content)}

        {:ok, %{content: content}} ->
          {:ok, content, estimate_tokens(content)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp estimate_tokens(text) when is_binary(text), do: ceil(String.length(text) / 4)
  defp estimate_tokens(_), do: 0

  # Project names come from the LLM — only allow a conservative charset
  # so they can't smuggle path separators or traversal into the dir name.
  defp safe_project_dir(name) do
    if is_binary(name) and name =~ ~r/^[a-zA-Z0-9 _\-]+$/ do
      {:ok, Path.join([Traitee.data_dir(), @workshop_dir, name])}
    else
      {:error, {:unsafe_project_name, inspect(name)}}
    end
  end

  # Guard every LLM-supplied relative path: skip (and log) anything that
  # resolves outside the project's workshop directory.
  defp safe_write(_base, relative, _content) when relative in [nil, ""], do: :skipped

  defp safe_write(base, relative, content) do
    expanded_base = Path.expand(base)
    full = Path.expand(Path.join(base, relative))

    if full == expanded_base or String.starts_with?(full, expanded_base <> "/") do
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      :ok
    else
      Logger.warning("[Workshop] Skipping file escaping workshop dir: #{inspect(relative)}")
      :skipped
    end
  end

  defp parse_json(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.replace(~r/^```json\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> Jason.decode()
  end

  defp parse_json(_), do: {:ok, %{}}

  defp safe_execute(command) do
    case Traitee.Security.Sandbox.check_command(command) do
      :ok ->
        Traitee.Process.Executor.run(command, timeout: 30_000)

      {:error, _} ->
        Logger.debug("[Workshop] Setup command blocked: #{command}")
        {:error, :blocked}
    end
  rescue
    _ -> {:error, :execution_failed}
  end

  defp update_status(project_id, status) do
    case Repo.get(WorkshopProject, project_id) do
      nil -> :ok
      project -> project |> WorkshopProject.changeset(%{status: status}) |> Repo.update()
    end
  rescue
    _ -> :ok
  end

  defp schedule_build_check do
    Process.send_after(self(), :build_check, @build_check_ms)
  end

  defp broadcast(event, meta) do
    Phoenix.PubSub.broadcast(Traitee.PubSub, "workshop:events", {:workshop, event, meta})
  rescue
    _ -> :ok
  end

  defp config(key, default) do
    Traitee.Config.get([:cognition, key]) || default
  rescue
    _ -> default
  end
end
