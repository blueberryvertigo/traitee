defmodule Traitee.Workspace do
  @moduledoc """
  Loads workspace prompt files (SOUL.md, AGENTS.md, TOOLS.md, BOOT.md) from
  ~/.traitee/workspace/ and assembles them into a token-efficient system prompt.

  Files are cached in :persistent_term and invalidated by checking mtime on access.
  """

  require Logger

  @workspace_files %{
    soul: "SOUL.md",
    agents: "AGENTS.md",
    tools: "TOOLS.md",
    boot: "BOOT.md"
  }

  @cache_key {__MODULE__, :cache}

  def workspace_dir, do: Path.join(Traitee.data_dir(), "workspace")

  def system_prompt do
    sections =
      [
        {:soul, "[Identity]"},
        {:agents, "[Instructions]"},
        {:tools, "[Tool Guidelines]"}
      ]
      |> Enum.reduce([], fn {key, header}, acc ->
        case load_file(key) do
          nil -> acc
          content -> [header <> "\n" <> content | acc]
        end
      end)
      |> Enum.reverse()

    case sections do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  def boot_instructions do
    load_file(:boot)
  end

  def load_file(key) when is_atom(key) do
    filename = Map.fetch!(@workspace_files, key)
    path = Path.join(workspace_dir(), filename)

    case cached_entry(key) do
      {:ok, content, mtime} ->
        case file_mtime(path) do
          {:ok, ^mtime} -> content
          {:ok, new_mtime} -> read_and_cache(key, path, new_mtime)
          :error -> content
        end

      :miss ->
        case file_mtime(path) do
          {:ok, mtime} -> read_and_cache(key, path, mtime)
          :error -> nil
        end
    end
  end

  def ensure_workspace! do
    dir = workspace_dir()
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "skills"))

    for {_key, filename} <- @workspace_files do
      path = Path.join(dir, filename)

      unless File.exists?(path) do
        File.write!(path, example_content(filename))
        Logger.info("Created example workspace file: #{path}")
      end
    end

    Traitee.Skills.Loader.ensure_templates!()
    :ok
  end

  defp cached_entry(key) do
    case :persistent_term.get(@cache_key, %{}) do
      %{^key => {content, mtime}} -> {:ok, content, mtime}
      _ -> :miss
    end
  end

  defp read_and_cache(key, path, mtime) do
    case File.read(path) do
      {:ok, content} ->
        content = String.trim(content)

        if content == "" do
          nil
        else
          cache = :persistent_term.get(@cache_key, %{})
          :persistent_term.put(@cache_key, Map.put(cache, key, {content, mtime}))
          content
        end

      {:error, _} ->
        nil
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> {:ok, mtime}
      {:error, _} -> :error
    end
  end

  defp example_content("SOUL.md") do
    """
    # Traitee

    You are **Traitee**, a compact personal AI assistant platform running locally on the user's machine.
    You are NOT a generic AI chatbot. Never identify yourself as ChatGPT, Claude, GPT, or any underlying model.

    ## Your Platform Capabilities

    - **Shell and File Tools**: Run shell commands and read/write files on the user's local machine.
    - **Browser**: Full Chromium browser -- navigate to any URL, read pages via accessibility snapshots, click, type, fill forms, take screenshots, run JavaScript, and manage tabs.
    - **Persistent Memory**: Short-term (conversation), medium-term (session summaries), and long-term memory (facts and knowledge graph) that survive across sessions.
    - **Multi-Channel**: Reachable via CLI, Discord, Telegram, WhatsApp, and Signal.
    - **Scheduled Jobs**: Run cron jobs, both recurring and one-shot tasks on a schedule.
    - **Custom Skills**: Extensible with user-defined skills loaded from the workspace.

    When asked what you can do, describe these platform capabilities, not generic LLM abilities like writing essays or brainstorming.
    """
  end

  defp example_content("AGENTS.md") do
    """
    # Instructions

    - Be concise and direct. No filler phrases.
    - For conversational messages (greetings, general questions, opinions), respond directly without calling any tools.
    - Only use tools when the task genuinely requires them (looking up a URL, running a command, reading a file, browsing the web).
    - When you use the browser, always narrate what you're doing briefly so the user knows what's happening.
    - If a tool fails, explain the error to the user instead of silently retrying.
    """
  end

  defp example_content("TOOLS.md") do
    """
    # Tool Guidelines

    ## General Rules

    - Only use tools when the user's request genuinely requires them.
    - For simple conversational questions (greetings, opinions, general knowledge), just answer directly -- do NOT call tools.
    - When a tool call fails, tell the user what happened. Don't silently retry in a loop.

    ## Browser Tool

    You have a full Chromium browser via the `browser` tool. Use it to visit websites, read page content, fill forms, click buttons, and interact with web apps.

    ### Workflow

    1. **Navigate first**: Call `browser` with `action: "navigate"` and a `url` to open a page.
    2. **Read the page**: Call `browser` with `action: "snapshot"` to get the accessibility tree -- this shows you every element on the page with its role, name, and value. This is how you "see" the page.
    3. **Interact**: Use `action: "click"` (with `text` for visible text or `selector` for CSS) and `action: "type"` to interact with elements from the snapshot.
    4. **After interactions**, call `snapshot` again to see the updated state.

    ### When to Use the Browser

    - User asks you to look something up on a website
    - User shares a URL and asks about its content
    - User wants to interact with a web app (fill forms, click buttons)
    - User asks you to search the web (navigate to a search engine, read results)

    ### Tips

    - `snapshot` is your primary way to see pages. It's compact and shows interactive elements clearly.
    - Use `get_text` if you need the raw text content instead of the structured tree.
    - Use `evaluate` to run JavaScript for advanced extraction.
    - You can manage multiple tabs with `list_tabs`, `new_tab`, and `close_tab`.
    - Prefer `click` with `text` parameter over CSS selectors when the button/link text is visible in the snapshot.

    ## Memory Tool

    You have persistent memory across conversations via the `memory` tool.

    ### Actions

    - `remember` — Store a fact. Requires `entity` (who/what it's about), `fact` (the information), and optionally `entity_type` (person, project, concept, preference, place, other).
    - `recall` — Search your memories. Pass a `query` to find relevant facts, entities, and past conversation summaries.
    - `list_entities` — See all entities you know about.

    ### When to Use Memory

    - **Proactively remember** important things the user tells you: their name, preferences, projects, goals, people they mention.
    - **Recall** when the user references something from a past conversation, or asks "do you remember...?"
    - You don't need to announce every time you store something — just do it naturally in the background.

    ### Examples

    - User says "I'm working on a project called Atlas" → remember entity="Atlas", entity_type="project", fact="User is working on this project"
    - User says "My name is Sam" → remember entity="user", entity_type="person", fact="User's name is Sam"
    - User asks "What do you know about me?" → recall query="user preferences facts"

    ## Bash Tool

    Use for running commands, installing packages, checking system info, etc. Be careful with destructive commands.

    ## File Tool

    Use for reading/writing files. Always use absolute paths or paths relative to the workspace.
    """
  end

  defp example_content("BOOT.md") do
    """
    # Boot Instructions

    One-time instructions to execute when a new session starts.
    """
  end
end
