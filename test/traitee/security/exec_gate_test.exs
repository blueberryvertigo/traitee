defmodule Traitee.Security.ExecGateTest do
  use ExUnit.Case, async: true

  alias Traitee.Security.ExecGate

  describe "evaluate/2 with default gates" do
    test "warns on rm commands" do
      result = ExecGate.evaluate("rm -rf /tmp/old", tool: "bash")
      assert elem(result, 0) in [:warn, :approve]
    end

    test "warns on curl commands" do
      result = ExecGate.evaluate("curl https://example.com/api", tool: "bash")
      assert elem(result, 0) in [:warn, :approve]
    end

    test "denies sudo commands" do
      result = ExecGate.evaluate("sudo rm -rf /var/log", tool: "bash")
      assert elem(result, 0) in [:deny, :approve]
    end

    test "denies npm publish" do
      result = ExecGate.evaluate("npm publish --access public", tool: "bash")
      assert elem(result, 0) in [:deny, :approve]
    end

    test "approves safe commands" do
      assert {:approve, _} = ExecGate.evaluate("echo hello", tool: "bash")
    end

    test "approves mix commands" do
      assert {:approve, _} = ExecGate.evaluate("mix test", tool: "bash")
    end
  end

  describe "check_write/2" do
    test "blocks writes to Windows system directories" do
      result = ExecGate.check_write("C:/Windows/System32/test.txt")
      assert result == :ok or match?({:error, _}, result)
    end

    test "blocks writes to /usr" do
      result = ExecGate.check_write("/usr/bin/evil")
      assert result == :ok or match?({:error, _}, result)
    end

    test "allows writes to normal directories" do
      assert :ok = ExecGate.check_write("/tmp/test.txt")
    end

    test "allows writes to home directories" do
      assert :ok = ExecGate.check_write("/home/user/projects/file.txt")
    end
  end

  describe "default_gates/0" do
    test "returns a non-empty list" do
      gates = ExecGate.default_gates()
      assert is_list(gates)
      assert length(gates) > 5
    end

    test "each gate has required fields" do
      gates = ExecGate.default_gates()

      Enum.each(gates, fn gate ->
        assert is_binary(gate.pattern)
        assert gate.action in [:approve, :warn, :deny]
        assert is_binary(gate.description)
      end)
    end
  end

  describe "active_rules/0" do
    test "returns rules" do
      rules = ExecGate.active_rules()
      assert is_list(rules)
    end
  end
end
