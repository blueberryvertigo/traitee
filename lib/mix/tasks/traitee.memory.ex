defmodule Mix.Tasks.Traitee.Memory do
  @moduledoc """
  Memory management commands.

      mix traitee.memory stats    -- Show memory statistics
      mix traitee.memory search QUERY -- Search across all memory tiers
      mix traitee.memory entities -- List known entities
      mix traitee.memory reindex  -- Rebuild the vector index
  """
  use Mix.Task

  alias Traitee.Context.Continuity
  alias Traitee.Memory.LTM
  alias Traitee.Memory.Schema.Message
  alias Traitee.Memory.Schema.Summary
  alias Traitee.Memory.Vector
  alias Traitee.Repo

  @shortdoc "Memory management commands"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["stats" | _] -> show_stats()
      ["search" | query_parts] -> search(Enum.join(query_parts, " "))
      ["entities" | _] -> list_entities()
      ["reindex" | _] -> reindex()
      _ -> usage()
    end
  end

  defp show_stats do
    ltm = LTM.stats()
    vectors = Vector.count()

    message_count = Repo.aggregate(Message, :count, :id)
    summary_count = Repo.aggregate(Summary, :count, :id)

    IO.puts("""

    Memory Statistics
    ═════════════════════════
    Messages (archive):  #{message_count}
    Summaries (MTM):     #{summary_count}
    Entities (LTM):      #{ltm.entities}
    Relations (LTM):     #{ltm.relations}
    Facts (LTM):         #{ltm.facts}
    Vectors indexed:     #{vectors}
    """)
  end

  defp search(query) do
    if query == "" do
      IO.puts("Usage: mix traitee.memory search <query>")
      return()
    end

    IO.puts("\nSearching for: \"#{query}\"\n")

    results = Continuity.recall(query)

    if results.entities != [] do
      IO.puts("Entities:")

      Enum.each(results.entities, fn e ->
        IO.puts("  [#{e.entity_type}] #{e.name} (mentioned #{e.mention_count}x)")
      end)

      IO.puts("")
    end

    if results.facts != [] do
      IO.puts("Facts:")

      Enum.each(Enum.take(results.facts, 10), fn f ->
        IO.puts("  - #{f.content}")
      end)

      IO.puts("")
    end

    if results.summaries != [] do
      IO.puts("Summaries:")

      Enum.each(Enum.take(results.summaries, 3), fn s ->
        IO.puts("  #{String.slice(s.content, 0, 200)}...")
        IO.puts("")
      end)
    end

    if results.entities == [] and results.facts == [] and results.summaries == [] do
      IO.puts("  No results found.")
    end
  end

  defp list_entities do
    entities = LTM.top_entities(50)

    if entities == [] do
      IO.puts("\nNo entities in memory yet.")
    else
      IO.puts("\nKnown Entities (#{length(entities)})")
      IO.puts("═════════════════════════")

      Enum.each(entities, fn e ->
        IO.puts("  [#{e.entity_type}] #{e.name} (#{e.mention_count}x)")
      end)
    end
  end

  defp reindex do
    IO.write("Rebuilding vector index... ")
    Vector.reindex()
    count = Vector.count()
    IO.puts("done. #{count} vectors indexed.")
  end

  defp usage do
    IO.puts("""

    Usage: mix traitee.memory <command>

    Commands:
      stats      Show memory statistics
      search Q   Search across all memory tiers
      entities   List known entities
      reindex    Rebuild the vector index
    """)
  end

  defp return, do: :ok
end
