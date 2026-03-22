defmodule Traitee.Memory.SchemaTest do
  use ExUnit.Case, async: true

  alias Traitee.Memory.Schema.{Message, Summary, Entity, Relation, Fact, Session}

  describe "Message.changeset/2" do
    test "valid changeset" do
      cs = Message.changeset(%Message{}, %{session_id: "s1", role: "user", content: "hello"})
      assert cs.valid?
    end

    test "requires session_id, role, content" do
      cs = Message.changeset(%Message{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :session_id)
      assert Keyword.has_key?(cs.errors, :role)
      assert Keyword.has_key?(cs.errors, :content)
    end

    test "validates role inclusion" do
      cs = Message.changeset(%Message{}, %{session_id: "s", role: "hacker", content: "hi"})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :role)
    end

    test "accepts all valid roles" do
      for role <- ["system", "user", "assistant", "tool"] do
        cs = Message.changeset(%Message{}, %{session_id: "s", role: role, content: "msg"})
        assert cs.valid?, "Expected role '#{role}' to be valid"
      end
    end

    test "casts optional fields" do
      cs =
        Message.changeset(%Message{}, %{
          session_id: "s",
          role: "user",
          content: "hi",
          channel: "discord",
          token_count: 42,
          metadata: %{key: "val"}
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :channel) == "discord"
      assert Ecto.Changeset.get_change(cs, :token_count) == 42
    end
  end

  describe "Summary.changeset/2" do
    test "valid changeset" do
      cs =
        Summary.changeset(%Summary{}, %{
          session_id: "s1",
          content: "Summary text",
          message_count: 20
        })

      assert cs.valid?
    end

    test "requires session_id, content, message_count" do
      cs = Summary.changeset(%Summary{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :session_id)
      assert Keyword.has_key?(cs.errors, :content)
      assert Keyword.has_key?(cs.errors, :message_count)
    end

    test "casts optional fields" do
      cs =
        Summary.changeset(%Summary{}, %{
          session_id: "s",
          content: "text",
          message_count: 10,
          message_range_start: 1,
          message_range_end: 10,
          key_topics: ["elixir", "otp"]
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :key_topics) == ["elixir", "otp"]
    end
  end

  describe "Entity.changeset/2" do
    test "valid changeset" do
      cs = Entity.changeset(%Entity{}, %{name: "Alice", entity_type: "person"})
      assert cs.valid?
    end

    test "requires name and entity_type" do
      cs = Entity.changeset(%Entity{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :name)
      assert Keyword.has_key?(cs.errors, :entity_type)
    end

    test "defaults mention_count to 1" do
      entity = %Entity{}
      assert entity.mention_count == 1
    end
  end

  describe "Relation.changeset/2" do
    test "valid changeset" do
      cs =
        Relation.changeset(%Relation{}, %{
          source_entity_id: 1,
          target_entity_id: 2,
          relation_type: "works_on"
        })

      assert cs.valid?
    end

    test "requires source, target, type" do
      cs = Relation.changeset(%Relation{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :source_entity_id)
      assert Keyword.has_key?(cs.errors, :target_entity_id)
      assert Keyword.has_key?(cs.errors, :relation_type)
    end

    test "defaults strength to 1.0" do
      assert %Relation{}.strength == 1.0
    end
  end

  describe "Fact.changeset/2" do
    test "valid changeset" do
      cs = Fact.changeset(%Fact{}, %{content: "Elixir uses BEAM", fact_type: "extracted"})
      assert cs.valid?
    end

    test "requires content and fact_type" do
      cs = Fact.changeset(%Fact{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :content)
      assert Keyword.has_key?(cs.errors, :fact_type)
    end

    test "defaults confidence to 1.0" do
      assert %Fact{}.confidence == 1.0
    end
  end

  describe "Session.changeset/2" do
    test "valid changeset" do
      cs = Session.changeset(%Session{}, %{session_id: "sess_123"})
      assert cs.valid?
    end

    test "requires session_id" do
      cs = Session.changeset(%Session{}, %{})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :session_id)
    end

    test "defaults status to active" do
      assert %Session{}.status == "active"
    end
  end
end
