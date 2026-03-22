defmodule Traitee.Config.ValidatorTest do
  use ExUnit.Case, async: true

  alias Traitee.Config.Validator

  describe "validate/1" do
    test "accepts valid config" do
      config = %{
        agent: %{model: "openai/gpt-4o", fallback_model: "anthropic/claude-sonnet-4"},
        memory: %{stm_capacity: 50, mtm_chunk_size: 20},
        gateway: %{port: 4000},
        channels: %{discord: %{enabled: true, token: "abc123"}},
        tools: %{bash: %{enabled: true}}
      }

      assert {:ok, ^config} = Validator.validate(config)
    end

    test "accepts empty/nil sections" do
      assert {:ok, _} = Validator.validate(%{})
    end

    test "rejects invalid model format" do
      config = %{agent: %{model: "not-a-valid-model"}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "agent.model"))
    end

    test "rejects non-string model" do
      config = %{agent: %{model: 123}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "must be a string"))
    end

    test "rejects enabled channel without token" do
      config = %{channels: %{discord: %{enabled: true, token: nil}}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "discord"))
    end

    test "accepts disabled channel without token" do
      config = %{channels: %{discord: %{enabled: false}}}
      assert {:ok, _} = Validator.validate(config)
    end

    test "rejects invalid memory values" do
      config = %{memory: %{stm_capacity: -1}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "stm_capacity"))
    end

    test "rejects invalid port" do
      config = %{gateway: %{port: 99_999}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "port"))
    end

    test "accepts valid port range" do
      assert {:ok, _} = Validator.validate(%{gateway: %{port: 1}})
      assert {:ok, _} = Validator.validate(%{gateway: %{port: 65_535}})
    end

    test "rejects invalid tool enabled value" do
      config = %{tools: %{bash: %{enabled: "yes"}}}
      assert {:error, errors} = Validator.validate(config)
      assert Enum.any?(errors, &String.contains?(&1, "boolean"))
    end
  end

  describe "validate_section/2" do
    test "validates agent section" do
      assert {:ok, _} = Validator.validate_section(:agent, %{model: "openai/gpt-4o"})
      assert {:error, _} = Validator.validate_section(:agent, %{model: "bad"})
    end

    test "rejects unknown section" do
      assert {:error, errors} = Validator.validate_section(:unknown, %{})
      assert Enum.any?(errors, &String.contains?(&1, "unknown section"))
    end
  end

  describe "warnings/1" do
    test "warns when no channel tokens configured" do
      config = %{channels: %{}}
      warnings = Validator.warnings(config)
      assert Enum.any?(warnings, &String.contains?(&1, "channel tokens"))
    end

    test "warns when no model configured" do
      config = %{agent: %{}}
      warnings = Validator.warnings(config)
      assert Enum.any?(warnings, &String.contains?(&1, "model"))
    end

    test "returns a list of warning strings" do
      config = %{}
      warnings = Validator.warnings(config)
      assert is_list(warnings)
      assert Enum.all?(warnings, &is_binary/1)
    end
  end
end
