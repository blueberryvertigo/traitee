defmodule Traitee.Memory.LTMTest do
  use Traitee.DataCase, async: false

  alias Traitee.Memory.LTM

  # -- Entities --

  describe "upsert_entity/3" do
    test "creates a new entity" do
      assert {:ok, entity} = LTM.upsert_entity("Alice", "person", "A software developer")
      assert entity.name == "Alice"
      assert entity.entity_type == "person"
      assert entity.description == "A software developer"
      assert entity.mention_count == 1
    end

    test "increments mention_count on re-upsert" do
      {:ok, _} = LTM.upsert_entity("Bob", "person")
      {:ok, updated} = LTM.upsert_entity("Bob", "person")
      assert updated.mention_count == 2
    end

    test "updates description on re-upsert when provided" do
      {:ok, _} = LTM.upsert_entity("Proj", "project", "Old desc")
      {:ok, updated} = LTM.upsert_entity("Proj", "project", "New desc")
      assert updated.description == "New desc"
    end

    test "preserves existing description if new one is nil" do
      {:ok, _} = LTM.upsert_entity("Proj2", "project", "Original")
      {:ok, updated} = LTM.upsert_entity("Proj2", "project", nil)
      assert updated.description == "Original"
    end

    test "different types create separate entities" do
      {:ok, person} = LTM.upsert_entity("Python", "person")
      {:ok, lang} = LTM.upsert_entity("Python", "concept")
      assert person.id != lang.id
    end
  end

  describe "get_entity_by_name/2" do
    test "returns entity when found" do
      {:ok, created} = LTM.upsert_entity("Eve", "person")
      found = LTM.get_entity_by_name("Eve", "person")
      assert found.id == created.id
    end

    test "returns nil when not found" do
      assert LTM.get_entity_by_name("Nobody", "person") == nil
    end
  end

  describe "search_entities/1" do
    test "finds entities by name pattern" do
      {:ok, _} = LTM.upsert_entity("Elixir Framework", "concept")
      {:ok, _} = LTM.upsert_entity("Rust Language", "concept")

      results = LTM.search_entities("Elixir")
      assert results != []
      assert Enum.any?(results, &(&1.name == "Elixir Framework"))
    end

    test "finds entities by description pattern" do
      {:ok, _} = LTM.upsert_entity("TeamLead", "person", "Manages the backend team")

      results = LTM.search_entities("backend")
      assert results != []
    end

    test "returns empty for no match" do
      assert LTM.search_entities("zzz_nonexistent_zzz") == []
    end

    test "orders by mention_count descending" do
      {:ok, _} = LTM.upsert_entity("Popular", "concept")
      {:ok, _} = LTM.upsert_entity("Popular", "concept")
      {:ok, _} = LTM.upsert_entity("Popular", "concept")
      {:ok, _} = LTM.upsert_entity("Unpopular", "concept")

      results = LTM.search_entities("opular")
      assert hd(results).name == "Popular"
    end
  end

  describe "top_entities/1" do
    test "returns most mentioned entities" do
      {:ok, _} = LTM.upsert_entity("TopEntity", "concept")
      {:ok, _} = LTM.upsert_entity("TopEntity", "concept")
      {:ok, _} = LTM.upsert_entity("LowEntity", "concept")

      top = LTM.top_entities(5)
      assert is_list(top)
      names = Enum.map(top, & &1.name)
      top_idx = Enum.find_index(names, &(&1 == "TopEntity"))
      low_idx = Enum.find_index(names, &(&1 == "LowEntity"))
      if top_idx && low_idx, do: assert(top_idx < low_idx)
    end
  end

  describe "all_entities/0" do
    test "returns all entities" do
      {:ok, _} = LTM.upsert_entity("AllTest1", "person")
      {:ok, _} = LTM.upsert_entity("AllTest2", "concept")

      all = LTM.all_entities()
      names = Enum.map(all, & &1.name)
      assert "AllTest1" in names
      assert "AllTest2" in names
    end
  end

  # -- Relations --

  describe "add_relation/4" do
    test "creates a relation between entities" do
      {:ok, alice} = LTM.upsert_entity("AliceR", "person")
      {:ok, proj} = LTM.upsert_entity("ProjectX", "project")

      assert {:ok, rel} = LTM.add_relation(alice.id, proj.id, "works_on", "Lead developer")
      assert rel.source_entity_id == alice.id
      assert rel.target_entity_id == proj.id
      assert rel.relation_type == "works_on"
      assert rel.description == "Lead developer"
    end

    test "increments strength on duplicate relation" do
      {:ok, a} = LTM.upsert_entity("RelA", "person")
      {:ok, b} = LTM.upsert_entity("RelB", "project")

      {:ok, r1} = LTM.add_relation(a.id, b.id, "uses")
      {:ok, r2} = LTM.add_relation(a.id, b.id, "uses")
      assert r2.strength > r1.strength
    end
  end

  describe "get_relations/1" do
    test "returns both incoming and outgoing relations" do
      {:ok, a} = LTM.upsert_entity("NodeA", "concept")
      {:ok, b} = LTM.upsert_entity("NodeB", "concept")
      {:ok, c} = LTM.upsert_entity("NodeC", "concept")

      {:ok, _} = LTM.add_relation(a.id, b.id, "related_to")
      {:ok, _} = LTM.add_relation(c.id, a.id, "depends_on")

      relations = LTM.get_relations(a.id)
      directions = Enum.map(relations, & &1.direction)
      assert :outgoing in directions
      assert :incoming in directions
    end
  end

  # -- Facts --

  describe "add_fact/4" do
    test "creates a fact linked to an entity" do
      {:ok, entity} = LTM.upsert_entity("FactTarget", "concept")

      assert {:ok, fact} =
               LTM.add_fact(entity.id, "Elixir compiles to BEAM bytecode", "extracted")

      assert fact.entity_id == entity.id
      assert fact.content == "Elixir compiles to BEAM bytecode"
      assert fact.fact_type == "extracted"
      assert fact.confidence == 1.0
    end
  end

  describe "get_facts/1" do
    test "returns all facts for an entity" do
      {:ok, entity} = LTM.upsert_entity("FactHolder", "concept")
      {:ok, _} = LTM.add_fact(entity.id, "Fact one", "extracted")
      {:ok, _} = LTM.add_fact(entity.id, "Fact two", "inferred")

      facts = LTM.get_facts(entity.id)
      assert length(facts) == 2
    end

    test "returns empty for entity with no facts" do
      {:ok, entity} = LTM.upsert_entity("NoFacts", "person")
      assert LTM.get_facts(entity.id) == []
    end
  end

  describe "search_facts/1" do
    test "finds facts by keyword" do
      {:ok, e} = LTM.upsert_entity("FactSearchE", "concept")
      {:ok, _} = LTM.add_fact(e.id, "GenServer handles state", "extracted")
      {:ok, _} = LTM.add_fact(e.id, "ETS is for shared state", "extracted")

      results = LTM.search_facts("GenServer")
      assert results != []
      assert hd(results).content =~ "GenServer"
    end

    test "returns empty for no match" do
      assert LTM.search_facts("zzz_impossible_zzz") == []
    end
  end

  # -- Graph Queries --

  describe "entity_context/1" do
    test "returns full subgraph for an entity" do
      {:ok, e} = LTM.upsert_entity("ContextEntity", "concept", "A test concept")
      {:ok, other} = LTM.upsert_entity("RelatedEntity", "concept")
      {:ok, _} = LTM.add_fact(e.id, "Important fact", "extracted")
      {:ok, _} = LTM.add_relation(e.id, other.id, "related_to")

      ctx = LTM.entity_context(e.id)
      assert ctx.entity.name == "ContextEntity"
      assert ctx.facts != []
      assert ctx.relations != []
    end

    test "returns nil for nonexistent entity" do
      assert LTM.entity_context(999_999) == nil
    end
  end

  describe "format_context/1" do
    test "returns empty string for nil" do
      assert LTM.format_context(nil) == ""
    end

    test "formats entity with facts and relations" do
      {:ok, e} = LTM.upsert_entity("FmtEntity", "tool", "A great tool")
      {:ok, other} = LTM.upsert_entity("FmtOther", "concept")
      {:ok, _} = LTM.add_fact(e.id, "It does amazing things", "extracted")
      {:ok, _} = LTM.add_relation(e.id, other.id, "integrates_with")

      ctx = LTM.entity_context(e.id)
      formatted = LTM.format_context(ctx)

      assert is_binary(formatted)
      assert formatted =~ "FmtEntity"
      assert formatted =~ "tool"
      assert formatted =~ "amazing things"
      assert formatted =~ "integrates_with"
    end
  end

  describe "stats/0" do
    test "returns counts for entities, relations, facts" do
      stats = LTM.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :entities)
      assert Map.has_key?(stats, :relations)
      assert Map.has_key?(stats, :facts)
      assert is_integer(stats.entities)
    end
  end
end
