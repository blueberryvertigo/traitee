defmodule Traitee.Tools.FileTest do
  use ExUnit.Case, async: true

  import Traitee.TestHelpers

  describe "schema" do
    test "name returns 'file'" do
      assert Traitee.Tools.File.name() == "file"
    end

    test "description is a string" do
      assert is_binary(Traitee.Tools.File.description())
    end

    test "parameters_schema is a valid JSON schema" do
      schema = Traitee.Tools.File.parameters_schema()
      assert is_map(schema)
      assert schema["type"] == "object"
    end
  end

  describe "execute/1 (read)" do
    test "reads a file" do
      dir = tmp_dir!()
      path = Path.join(dir, "test.txt")
      File.write!(path, "hello world")

      result = Traitee.Tools.File.execute(%{"operation" => "read", "path" => path})
      assert {:ok, content} = result
      assert content =~ "hello world"

      File.rm_rf!(dir)
    end

    test "returns error for missing file" do
      result =
        Traitee.Tools.File.execute(%{"operation" => "read", "path" => "/nonexistent/file.txt"})

      assert {:error, _} = result
    end
  end

  describe "execute/1 (write)" do
    test "writes a file" do
      dir = tmp_dir!()
      path = Path.join(dir, "output.txt")

      result =
        Traitee.Tools.File.execute(%{
          "operation" => "write",
          "path" => path,
          "content" => "written"
        })

      assert {:ok, _} = result
      assert File.read!(path) == "written"

      File.rm_rf!(dir)
    end

    test "creates parent directories" do
      dir = tmp_dir!()
      path = Path.join([dir, "nested", "deep", "file.txt"])

      result =
        Traitee.Tools.File.execute(%{
          "operation" => "write",
          "path" => path,
          "content" => "nested"
        })

      assert {:ok, _} = result
      assert File.exists?(path)

      File.rm_rf!(dir)
    end
  end

  describe "execute/1 (append)" do
    test "appends to a file" do
      dir = tmp_dir!()
      path = Path.join(dir, "append.txt")
      File.write!(path, "first\n")

      result =
        Traitee.Tools.File.execute(%{
          "operation" => "append",
          "path" => path,
          "content" => "second\n"
        })

      assert {:ok, _} = result
      assert File.read!(path) == "first\nsecond\n"

      File.rm_rf!(dir)
    end
  end

  describe "execute/1 (list)" do
    test "lists directory contents" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "a.txt"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      result = Traitee.Tools.File.execute(%{"operation" => "list", "path" => dir})
      assert {:ok, listing} = result
      assert listing =~ "a.txt"
      assert listing =~ "b.txt"

      File.rm_rf!(dir)
    end
  end

  describe "execute/1 (exists)" do
    test "returns truthy for existing file" do
      dir = tmp_dir!()
      path = Path.join(dir, "exists.txt")
      File.write!(path, "")

      result = Traitee.Tools.File.execute(%{"operation" => "exists", "path" => path})
      assert {:ok, msg} = result
      assert msg =~ "true" or msg =~ "exists"

      File.rm_rf!(dir)
    end

    test "returns falsy for missing file" do
      result = Traitee.Tools.File.execute(%{"operation" => "exists", "path" => "/no/such/file"})
      assert {:ok, msg} = result
      assert msg =~ "false" or msg =~ "not" or msg =~ "does not"
    end
  end
end
