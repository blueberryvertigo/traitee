defmodule Traitee.Tools.FileTest do
  use ExUnit.Case, async: true

  alias Traitee.Tools.File, as: FileTool

  import Traitee.TestHelpers

  describe "execute/1 sandbox enforcement" do
    test "blocks reading from .ssh directory" do
      result = FileTool.execute(%{"operation" => "read", "path" => "/home/user/.ssh/id_rsa"})
      assert {:error, msg} = result
      assert msg =~ ".ssh"
    end

    test "blocks writing to .env file" do
      result =
        FileTool.execute(%{
          "operation" => "write",
          "path" => "/tmp/.env",
          "content" => "SECRET=x"
        })

      assert {:error, msg} = result
      assert msg =~ ".env"
    end

    test "blocks reading credentials.json" do
      result = FileTool.execute(%{"operation" => "read", "path" => "/home/user/credentials.json"})
      assert {:error, msg} = result
      assert msg =~ "credentials.json"
    end

    test "blocks listing .aws directory" do
      result = FileTool.execute(%{"operation" => "list", "path" => "/home/user/.aws"})
      assert {:error, msg} = result
      assert msg =~ ".aws"
    end

    test "blocks exists check on secrets.toml" do
      result = FileTool.execute(%{"operation" => "exists", "path" => "/app/secrets.toml"})
      assert {:error, msg} = result
      assert msg =~ "secrets.toml"
    end

    test "allows reading a safe file" do
      dir = tmp_dir!()
      on_exit(fn -> File.rm_rf!(dir) end)

      safe_file = Path.join(dir, "notes.txt")
      File.write!(safe_file, "hello")

      assert {:ok, "hello"} = FileTool.execute(%{"operation" => "read", "path" => safe_file})
    end

    test "allows writing to a safe path" do
      dir = tmp_dir!()
      on_exit(fn -> File.rm_rf!(dir) end)

      safe_file = Path.join(dir, "output.txt")

      assert {:ok, _} =
               FileTool.execute(%{
                 "operation" => "write",
                 "path" => safe_file,
                 "content" => "data"
               })

      assert File.read!(safe_file) == "data"
    end

    test "allows listing a safe directory" do
      dir = tmp_dir!()
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "a.txt"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      assert {:ok, listing} = FileTool.execute(%{"operation" => "list", "path" => dir})
      assert listing =~ "a.txt"
      assert listing =~ "b.txt"
    end
  end

  describe "execute/1 basic operations" do
    test "returns error for missing parameters" do
      assert {:error, "Missing required parameters: operation, path"} = FileTool.execute(%{})
    end

    test "returns error for unknown operation" do
      assert {:error, "Unknown operation: delete"} =
               FileTool.execute(%{"operation" => "delete", "path" => "/tmp/x"})
    end
  end
end
