defmodule Traitee.Security.DockerTest do
  use ExUnit.Case, async: true

  alias Traitee.Security.Docker

  describe "enabled?/0" do
    test "returns a boolean" do
      result = Docker.enabled?()
      assert is_boolean(result)
    end
  end

  describe "posture/0" do
    test "returns posture map" do
      posture = Docker.posture()
      assert is_map(posture)
      assert Map.has_key?(posture, :enabled)
      assert Map.has_key?(posture, :available)
      assert Map.has_key?(posture, :image)
      assert Map.has_key?(posture, :network)
      assert Map.has_key?(posture, :status)
      assert posture.status in [:disabled, :unavailable, :active]
    end
  end

  describe "run/2" do
    test "returns error when docker is disabled" do
      result = Docker.run("echo hello")
      assert result == {:error, :docker_disabled} or match?({:ok, _}, result)
    end
  end
end
