defmodule Traitee.Skills.Loader do
  @moduledoc """
  3-tier progressive skill disclosure system.

  - Tier 1: Skill metadata (always in context via `skill_context_summary/0`)
  - Tier 2: Full SKILL.md body (loaded on trigger via `load_skill/1`)
  - Tier 3: Resource files from skill directory (on-demand via `load_resource/2`)

  Skills live in ~/.traitee/workspace/skills/<skill-name>/SKILL.md
  """

  require Logger

  @cache_key {__MODULE__, :metadata}
  @cache_ts_key {__MODULE__, :scanned_at}
  @ttl_ms 60_000

  def skills_dir, do: Path.join(Traitee.Workspace.workspace_dir(), "skills")

  def scan do
    if stale?() do
      do_scan()
    else
      :persistent_term.get(@cache_key, [])
    end
  end

  def load_skill(name) when is_binary(name) do
    path = skill_md_path(name)

    case File.read(path) do
      {:ok, raw} -> {:ok, strip_frontmatter(raw)}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_resource(skill_name, resource_path)
      when is_binary(skill_name) and is_binary(resource_path) do
    base = Path.join(skills_dir(), skill_name)
    full = Path.join(base, resource_path)

    if String.starts_with?(Path.expand(full), Path.expand(base)) do
      File.read(full)
    else
      {:error, :path_traversal}
    end
  end

  def skill_context_summary do
    scan()
    |> Enum.filter(& &1.enabled)
    |> Enum.map_join("\n", fn s -> "- #{s.name}: #{s.description}" end)
  end

  def match_skills(message) when is_binary(message) do
    words = message |> String.downcase() |> String.split(~r/\W+/, trim: true) |> MapSet.new()

    scan()
    |> Enum.filter(fn skill ->
      skill.enabled &&
        skill.description
        |> String.downcase()
        |> String.split(~r/\W+/, trim: true)
        |> Enum.any?(&MapSet.member?(words, &1))
    end)
  end

  def invalidate_cache do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@cache_ts_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp do_scan do
    dir = skills_dir()

    skills =
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(dir, &1)))
          |> Enum.flat_map(fn name ->
            case parse_skill_meta(name) do
              {:ok, meta} -> [meta]
              :error -> []
            end
          end)

        {:error, _} ->
          []
      end

    :persistent_term.put(@cache_key, skills)
    :persistent_term.put(@cache_ts_key, System.monotonic_time(:millisecond))
    skills
  end

  defp parse_skill_meta(name) do
    path = skill_md_path(name)

    case File.read(path) do
      {:ok, raw} ->
        case parse_frontmatter(raw) do
          {:ok, fm} ->
            enabled = fm["enabled"] != false and requirement_met?(fm["requires"])

            {:ok,
             %{
               name: fm["name"] || name,
               description: fm["description"] || "",
               version: fm["version"] || "1.0",
               enabled: enabled
             }}

          :error ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  defp requirement_met?(nil), do: true

  defp requirement_met?(executable) when is_binary(executable) do
    System.find_executable(executable) != nil
  end

  defp requirement_met?(_), do: true

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, yaml] ->
        meta =
          yaml
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, ":", parts: 2) do
              [key, val] ->
                Map.put(acc, String.trim(key), parse_yaml_value(String.trim(val)))

              _ ->
                acc
            end
          end)

        {:ok, meta}

      _ ->
        :error
    end
  end

  defp parse_yaml_value("true"), do: true
  defp parse_yaml_value("false"), do: false
  defp parse_yaml_value("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp parse_yaml_value("'" <> rest), do: String.trim_trailing(rest, "'")
  defp parse_yaml_value(val), do: val

  defp strip_frontmatter(content) do
    case Regex.replace(~r/\A---\n.*?\n---\n?/s, content, "", global: false) do
      stripped -> String.trim(stripped)
    end
  end

  @doc "Bootstraps template skills into the skills directory if they don't already exist."
  def ensure_templates! do
    dir = skills_dir()

    for {name, content} <- template_skills() do
      skill_dir = Path.join(dir, name)
      skill_path = Path.join(skill_dir, "SKILL.md")

      unless File.exists?(skill_path) do
        File.mkdir_p!(skill_dir)
        File.write!(skill_path, content)
        Logger.info("Created template skill: #{name}")
      end
    end

    :ok
  end

  defp template_skills do
    [
      {"self-reflect", self_reflect_skill()},
      {"create-skill", create_skill_skill()}
    ]
  end

  defp self_reflect_skill do
    """
    ---
    name: self-reflect
    description: Review errors patterns learnings corrections and propose or apply self-improvements
    enabled: true
    version: "1.0"
    ---

    # Self-Reflection and Improvement

    You are performing a self-reflection cycle. Your goal is to identify patterns
    in past errors, corrections, and interactions, then propose or apply improvements.

    ## Mode

    Check the evolution mode before proceeding:
    - Use the `bash` tool to run: `cat ~/.traitee/config.toml | grep -A2 evolution`
    - If mode is `"auto"`: apply improvements directly
    - If mode is `"propose"` (default): write proposals and present them to the user

    ## Reflection Process

    ### Step 1: Gather Evidence

    1. Use the `memory` tool with action `recall` to search for: "error", "mistake",
       "correction", "failed", "retry"
    2. Use the `file` tool to read the `.learnings/` directory contents if it exists
    3. Use the `memory` tool with action `list_entities` to review known entities

    ### Step 2: Identify Patterns

    Look for:
    - Repeated errors with the same tool or approach
    - User corrections that indicate a misunderstanding
    - Topics where you lack knowledge but the user has provided guidance
    - Workflows that could be encoded as skills

    ### Step 3: Propose Improvements

    For each identified pattern, determine the appropriate fix:
    - **New skill**: If a workflow is repeated, create a skill using the create-skill workflow
    - **Workspace edit**: If instructions need updating, modify AGENTS.md or TOOLS.md
    - **Memory store**: If facts need remembering, use the memory tool
    - **Config change**: If tool settings need adjusting, edit config.toml

    ### Step 4: Apply or Propose

    In **propose** mode:
    1. Create `.learnings/proposals/` directory if needed
    2. Write a proposal file: `.learnings/proposals/YYYY-MM-DD_<short-name>.md`
    3. Include: what was observed, what improvement is proposed, what files would change
    4. Tell the user about the proposal

    In **auto** mode:
    1. Apply the changes directly
    2. Log every change to `.learnings/changelog.md` with timestamp and description

    ### Step 5: Schedule Follow-up

    If the cron tool is available, consider scheduling periodic reflection:
    - Use the `cron` tool to add a job that triggers self-reflection on a regular schedule
    - Suggested: daily or weekly depending on activity level
    """
  end

  defp create_skill_skill do
    """
    ---
    name: create-skill
    description: Create new skills by writing SKILL.md files with proper format frontmatter and structure
    enabled: true
    version: "1.0"
    ---

    # Creating a New Skill

    Follow this process to create a new skill that will be auto-discovered by the system.

    ## Skill Format

    Each skill is a directory under `~/.traitee/workspace/skills/<skill-name>/` containing
    a `SKILL.md` file.

    ### SKILL.md Structure

    The file must start with YAML frontmatter between `---` markers, followed by a markdown body:

    ```
    ---
    name: my-skill-name
    description: A one-line description of what this skill does (used for matching)
    enabled: true
    version: "1.0"
    requires: curl
    ---

    # Skill Title

    Instructions for the agent when this skill is activated...
    ```

    ### Frontmatter Fields

    | Field       | Required | Description                                        |
    |-------------|----------|----------------------------------------------------|
    | name        | yes      | Unique skill name (lowercase, hyphens)             |
    | description | yes      | One-line description used for keyword matching      |
    | enabled     | no       | Set to false to disable (default: true)            |
    | version     | no       | Semantic version string                            |
    | requires    | no       | System executable that must exist on PATH           |

    ### Body Guidelines

    The markdown body should contain:
    1. Clear step-by-step instructions the agent should follow
    2. What tools to use and how
    3. Expected inputs and outputs
    4. Error handling guidance
    5. Examples if helpful

    ## Creation Process

    1. Choose a descriptive, lowercase, hyphenated name
    2. Use the `file` tool to create the directory:
       `~/.traitee/workspace/skills/<name>/`
    3. Use the `file` tool to write the SKILL.md file with proper frontmatter
    4. The skill will be auto-discovered within 60 seconds
    5. Optionally add resource files in the same directory (templates, configs, etc.)

    ## Tips

    - Keep descriptions keyword-rich for better matching
    - Use the `requires` field if the skill depends on external tools
    - Skills can reference other skills by name in their instructions
    - Resource files in the skill directory can be loaded on demand
    - Log skill creation to `.learnings/changelog.md` for auditability
    """
  end

  @protected_skills ~w(self-reflect create-skill)
  @name_pattern ~r/^[a-z0-9][a-z0-9\-]*$/

  @doc "Creates a new skill directory and SKILL.md with the given frontmatter and body."
  def create_skill(name, %{} = meta, body) when is_binary(name) and is_binary(body) do
    with :ok <- validate_name(name),
         :ok <- ensure_not_exists(name) do
      frontmatter = build_frontmatter(name, meta)
      content = frontmatter <> "\n" <> String.trim(body) <> "\n"

      dir = Path.join(skills_dir(), name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), content)
      invalidate_cache()
      {:ok, "Created skill: #{name}"}
    end
  end

  @doc "Replaces the full body of an existing SKILL.md, preserving frontmatter."
  def update_skill(name, new_body) when is_binary(name) and is_binary(new_body) do
    path = skill_md_path(name)

    with {:ok, raw} <- File.read(path),
         {:ok, fm_block} <- extract_frontmatter_block(raw) do
      content = fm_block <> "\n" <> String.trim(new_body) <> "\n"
      File.write!(path, content)
      invalidate_cache()
      {:ok, "Updated skill: #{name}"}
    else
      {:error, :enoent} -> {:error, "Skill not found: #{name}"}
      error -> error
    end
  end

  @doc "Patches an existing SKILL.md with substring replacement."
  def patch_skill(name, old_string, new_string)
      when is_binary(name) and is_binary(old_string) and is_binary(new_string) do
    path = skill_md_path(name)

    with {:ok, raw} <- File.read(path),
         :ok <- validate_unique_match(raw, old_string) do
      new_content = String.replace(raw, old_string, new_string, global: false)
      File.write!(path, new_content)
      invalidate_cache()
      {:ok, "Patched skill: #{name}"}
    else
      {:error, :enoent} -> {:error, "Skill not found: #{name}"}
      error -> error
    end
  end

  @doc "Deletes a skill directory. Refuses to delete protected template skills."
  def delete_skill(name) when is_binary(name) do
    if name in @protected_skills do
      {:error, "Cannot delete protected skill: #{name}"}
    else
      dir = Path.join(skills_dir(), name)

      if File.dir?(dir) do
        File.rm_rf!(dir)
        invalidate_cache()
        {:ok, "Deleted skill: #{name}"}
      else
        {:error, "Skill not found: #{name}"}
      end
    end
  end

  defp validate_name(name) do
    if Regex.match?(@name_pattern, name) do
      :ok
    else
      {:error, "Invalid skill name: use lowercase letters, numbers, and hyphens only"}
    end
  end

  defp ensure_not_exists(name) do
    if File.exists?(skill_md_path(name)) do
      {:error, "Skill already exists: #{name}. Use patch or edit to modify."}
    else
      :ok
    end
  end

  defp build_frontmatter(name, meta) do
    desc = meta[:description] || meta["description"] || ""
    version = meta[:version] || meta["version"] || "1.0"

    "---\nname: #{name}\ndescription: #{desc}\nenabled: true\nversion: \"#{version}\"\n---\n"
  end

  defp extract_frontmatter_block(content) do
    case Regex.run(~r/\A(---\n.*?\n---\n?)/s, content) do
      [_, block] -> {:ok, block}
      _ -> {:error, "No frontmatter found in SKILL.md"}
    end
  end

  defp validate_unique_match(content, old_string) do
    case length(String.split(content, old_string)) - 1 do
      0 -> {:error, "Substring not found"}
      1 -> :ok
      n -> {:error, "Substring matches #{n} locations — provide a more specific match"}
    end
  end

  defp skill_md_path(name), do: Path.join([skills_dir(), name, "SKILL.md"])

  defp stale? do
    case :persistent_term.get(@cache_ts_key, nil) do
      nil -> true
      ts -> System.monotonic_time(:millisecond) - ts > @ttl_ms
    end
  end
end
