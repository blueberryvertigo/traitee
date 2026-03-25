defmodule Traitee.LLM.AnthropicSharedTest do
  use ExUnit.Case, async: true

  alias Traitee.LLM.AnthropicShared
  alias Traitee.LLM.Types.{CompletionResponse, ModelInfo}

  describe "merge_system/2" do
    test "both nil returns nil" do
      assert AnthropicShared.merge_system(nil, nil) == nil
    end

    test "first nil returns second" do
      assert AnthropicShared.merge_system(nil, "b") == "b"
    end

    test "second nil returns first" do
      assert AnthropicShared.merge_system("a", nil) == "a"
    end

    test "both present joins with double newline" do
      assert AnthropicShared.merge_system("a", "b") == "a\n\nb"
    end
  end

  describe "extract_system/1" do
    test "separates system messages" do
      messages = [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hello"}
      ]

      {system, other} = AnthropicShared.extract_system(messages)
      assert system == "You are helpful"
      assert length(other) == 1
      assert hd(other).role == "user"
    end

    test "returns nil system when no system messages" do
      messages = [%{role: "user", content: "Hello"}]
      {system, _other} = AnthropicShared.extract_system(messages)
      assert system == nil
    end

    test "joins multiple system messages" do
      messages = [
        %{role: "system", content: "First"},
        %{role: "system", content: "Second"},
        %{role: "user", content: "Hello"}
      ]

      {system, other} = AnthropicShared.extract_system(messages)
      assert system == "First\n\nSecond"
      assert length(other) == 1
    end
  end

  describe "resolve_model_id/2" do
    test "resolves known model to full ID" do
      models = %{"claude-sonnet-4" => %ModelInfo{id: "claude-sonnet-4-20250514"}}

      assert AnthropicShared.resolve_model_id("claude-sonnet-4", models) ==
               "claude-sonnet-4-20250514"
    end

    test "passes through unknown model as-is" do
      assert AnthropicShared.resolve_model_id("custom-model", %{}) == "custom-model"
    end
  end

  describe "thinking_model?/2" do
    test "returns true for thinking models" do
      thinking = MapSet.new(["claude-opus-4.6"])
      assert AnthropicShared.thinking_model?("claude-opus-4.6", thinking)
    end

    test "returns false for non-thinking models" do
      thinking = MapSet.new(["claude-opus-4.6"])
      refute AnthropicShared.thinking_model?("claude-sonnet-4", thinking)
    end
  end

  describe "format_message/1" do
    test "formats plain user message" do
      msg = %{role: "user", content: "Hello"}
      assert AnthropicShared.format_message(msg) == %{role: "user", content: "Hello"}
    end

    test "formats tool result as user with tool_result block" do
      msg = %{role: "tool", tool_call_id: "call_123", content: "output"}
      result = AnthropicShared.format_message(msg)

      assert result.role == "user"
      assert [%{type: "tool_result", tool_use_id: "call_123", content: "output"}] = result.content
    end

    test "formats assistant with tool calls" do
      msg = %{
        role: "assistant",
        content: "Let me check",
        tool_calls: [
          %{
            "id" => "call_1",
            "function" => %{"name" => "bash", "arguments" => ~s({"command": "ls"})}
          }
        ]
      }

      result = AnthropicShared.format_message(msg)
      assert result.role == "assistant"

      assert [%{type: "text", text: "Let me check"}, %{type: "tool_use", name: "bash"}] =
               result.content
    end

    test "formats Message struct" do
      msg = %Traitee.LLM.Types.Message{role: "user", content: "Hi"}
      assert AnthropicShared.format_message(msg) == %{role: "user", content: "Hi"}
    end
  end

  describe "parse_tool_input/1" do
    test "parses JSON string" do
      assert AnthropicShared.parse_tool_input(~s({"key": "value"})) == %{"key" => "value"}
    end

    test "passes through map" do
      assert AnthropicShared.parse_tool_input(%{"key" => "value"}) == %{"key" => "value"}
    end

    test "returns empty map for invalid JSON" do
      assert AnthropicShared.parse_tool_input("not json") == %{}
    end

    test "returns empty map for nil" do
      assert AnthropicShared.parse_tool_input(nil) == %{}
    end
  end

  describe "merge_consecutive_roles/1" do
    test "merges consecutive same-role messages" do
      messages = [
        %{role: "user", content: "a"},
        %{role: "user", content: "b"},
        %{role: "assistant", content: "c"}
      ]

      result = AnthropicShared.merge_consecutive_roles(messages)
      assert length(result) == 2
      assert hd(result).content == "a\nb"
    end

    test "preserves alternating roles" do
      messages = [
        %{role: "user", content: "a"},
        %{role: "assistant", content: "b"},
        %{role: "user", content: "c"}
      ]

      result = AnthropicShared.merge_consecutive_roles(messages)
      assert length(result) == 3
    end
  end

  describe "parse_response/1" do
    test "parses text-only response" do
      resp = %{
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      assert %CompletionResponse{
               content: "Hello!",
               tool_calls: nil,
               model: "claude-sonnet-4-20250514",
               finish_reason: "end_turn",
               usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
             } = AnthropicShared.parse_response(resp)
    end

    test "parses response with tool calls" do
      resp = %{
        "content" => [
          %{"type" => "text", "text" => "Running..."},
          %{
            "type" => "tool_use",
            "id" => "call_1",
            "name" => "bash",
            "input" => %{"command" => "ls"}
          }
        ],
        "model" => "claude-sonnet-4-20250514",
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
      }

      result = AnthropicShared.parse_response(resp)
      assert result.content == "Running..."
      assert [%{"id" => "call_1", "type" => "function", "function" => func}] = result.tool_calls
      assert func["name"] == "bash"
      assert func["arguments"] == ~s({"command":"ls"})
    end
  end

  describe "maybe_put/3" do
    test "skips nil values" do
      assert AnthropicShared.maybe_put(%{a: 1}, :b, nil) == %{a: 1}
    end

    test "adds non-nil values" do
      assert AnthropicShared.maybe_put(%{a: 1}, :b, 2) == %{a: 1, b: 2}
    end

    test "skips __skip__ key" do
      assert AnthropicShared.maybe_put(%{a: 1}, :__skip__, "val") == %{a: 1}
    end
  end

  describe "maybe_put_tools/2" do
    test "returns map unchanged for nil tools" do
      assert AnthropicShared.maybe_put_tools(%{}, nil) == %{}
    end

    test "returns map unchanged for empty tools" do
      assert AnthropicShared.maybe_put_tools(%{}, []) == %{}
    end

    test "converts OpenAI tool format to Anthropic format" do
      tools = [
        %{
          "function" => %{
            "name" => "bash",
            "description" => "Run commands",
            "parameters" => %{"type" => "object"}
          }
        }
      ]

      result = AnthropicShared.maybe_put_tools(%{}, tools)

      assert [%{name: "bash", description: "Run commands", input_schema: %{"type" => "object"}}] =
               result.tools
    end
  end

  describe "maybe_put_thinking/2" do
    test "no-op when false" do
      assert AnthropicShared.maybe_put_thinking(%{a: 1}, false) == %{a: 1}
    end

    test "adds thinking config when true" do
      result = AnthropicShared.maybe_put_thinking(%{}, true)
      assert result.thinking == %{type: "adaptive"}
      assert result.output_config == %{effort: "medium"}
    end
  end
end
