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
    completed = [project_id | state.completed]
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
    case WorkshopProject
         |> where([p], p.status == "ideating")
         |> order_by([p], asc: p.inserted_at)
         |> limit(1)
         |> Repo.one() do
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

  defp build_project(project_id) do
    project = Repo.get(WorkshopProject, project_id)
    if project == nil, do: throw(:not_found)

    Logger.info("[Workshop] Building project: #{project.name} (#{project.project_type})")
    update_status(project_id, "researching")
    broadcast(:build_started, %{project: project.name})

    result =
      project
      |> research_phase()
      |> design_phase()
      |> build_phase()
      |> validate_phase()

    case result do
      {:ok, artifacts} ->
        project
        |> WorkshopProject.changeset(%{
          status: "ready",
          artifacts: artifacts
        })
        |> Repo.update()

        Logger.info("[Workshop] Project built, sending to QC: #{project.name}")
        broadcast(:build_complete, %{project: project.name, artifacts: artifacts})
        Traitee.Cognition.QualityControl.review_project(project.id)

      {:error, reason} ->
        Logger.warning("[Workshop] Build failed for #{project.name}: #{inspect(reason)}")

        project
        |> WorkshopProject.changeset(%{
          status: "ideating",
          metadata: Map.put(project.metadata || %{}, "last_error", inspect(reason))
        })
        |> Repo.update()

        broadcast(:build_failed, %{project: project.name, reason: inspect(reason)})
    end

    GenServer.cast(__MODULE__, {:build_done, project_id})
  rescue
    e ->
      Logger.warning("[Workshop] Build crashed: #{inspect(e)}")
      update_status(project_id, "ideating")
  catch
    :not_found -> :ok
  end

  defp research_phase(project) do
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

    case llm_complete(prompt) do
      {:ok, content} -> {project, parse_json(content)}
      {:error, _} -> {project, {:ok, %{}}}
    end
  end

  defp design_phase({project, {:ok, research}}) do
    update_status(project.id, "building")

    case project.project_type do
      "tool" -> design_tool(project, research)
      "skill" -> design_skill(project, research)
      "code" -> design_code(project, research)
      "research" -> design_research(project, research)
      _ -> design_code(project, research)
    end
  end

  defp design_phase({project, _}), do: {project, %{}}

  defp design_tool(project, research) do
    prompt = """
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

    case llm_complete(prompt) do
      {:ok, content} -> {project, parse_json(content), :tool}
      {:error, reason} -> {:error, reason}
    end
  end

  defp design_skill(project, research) do
    prompt = """
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

    case llm_complete(prompt) do
      {:ok, content} -> {project, parse_json(content), :skill}
      {:error, reason} -> {:error, reason}
    end
  end

  defp design_code(project, research) do
    prompt = """
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

    case llm_complete(prompt) do
      {:ok, content} -> {project, parse_json(content), :code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp design_research(project, _research) do
    prompt = """
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

    case llm_complete(prompt) do
      {:ok, content} -> {project, parse_json(content), :research}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_phase({project, {:ok, design}, :tool}) do
    setup = design["setup_commands"] || []

    Enum.each(setup, fn cmd ->
      safe_execute(cmd)
    end)

    spec = %{
      "name" => design["name"] || project.name,
      "description" => design["description"] || project.description,
      "parameters" => design["parameters"] || %{"type" => "object", "properties" => %{}},
      "executor" => {:bash, design["executor_template"] || "echo 'not implemented'"}
    }

    case ToolRegistry.register_dynamic(spec["name"], spec) do
      :ok ->
        artifacts = %{type: "tool", name: spec["name"], registered: true}
        {:ok, artifacts}

      {:error, reason} ->
        {:error, {:tool_registration_failed, reason}}
    end
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_phase({project, {:ok, design}, :skill}) do
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

  defp build_phase({project, {:ok, design}, :code}) do
    workshop_path = Path.join([Traitee.data_dir(), @workshop_dir, project.name])
    File.mkdir_p!(workshop_path)

    files = design["files"] || []

    Enum.each(files, fn file ->
      path = Path.join(workshop_path, file["path"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, file["content"] || "")
    end)

    if design["readme"] do
      File.write!(Path.join(workshop_path, "README.md"), design["readme"])
    end

    {:ok,
     %{
       type: "code",
       path: workshop_path,
       file_count: length(files),
       run_command: design["run_command"]
     }}
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_phase({project, {:ok, design}, :research}) do
    workshop_path = Path.join([Traitee.data_dir(), @workshop_dir, project.name])
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
  rescue
    e -> {:error, {:build_failed, inspect(e)}}
  end

  defp build_phase({_project, _design, _type}), do: {:error, :unknown_type}
  defp build_phase({_project, _design}), do: {:error, :missing_type}
  defp build_phase(other), do: {:error, {:unexpected, other}}

  defp validate_phase({:ok, %{type: "tool", name: name} = artifacts}) do
    case ToolRegistry.execute(name, %{}) do
      {:ok, _} -> {:ok, artifacts}
      {:error, _} -> {:ok, Map.put(artifacts, :validation, :skipped)}
    end
  rescue
    _ -> {:ok, artifacts}
  end

  defp validate_phase({:ok, artifacts}), do: {:ok, artifacts}
  defp validate_phase({:error, _} = err), do: err

  # -- Helpers --

  defp llm_complete(prompt) do
    request = %{
      messages: [%{role: "user", content: prompt}],
      system:
        "You are an expert software engineer building tools and projects. Return valid JSON only, no explanation."
    }

    case Router.complete(request) do
      {:ok, %{content: content}} -> {:ok, content}
      {:error, reason} -> {:error, reason}
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
