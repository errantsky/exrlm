defmodule RLM.Agent.ToolTest do
  use ExUnit.Case, async: true

  alias RLM.Agent.ToolRegistry
  alias RLM.Agent.Tools.{ReadFile, WriteFile, EditFile, Bash, Glob, Ls, Grep}

  # Use a unique temp dir per test
  setup do
    dir = Path.join(System.tmp_dir!(), "rlm_tool_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ---------------------------------------------------------------------------
  # ToolRegistry
  # ---------------------------------------------------------------------------

  describe "ToolRegistry" do
    test "specs/0 returns a list of maps with name and input_schema" do
      specs = ToolRegistry.specs()
      assert length(specs) >= 7

      for spec <- specs do
        assert is_binary(spec["name"])
        assert is_binary(spec["description"])
        assert is_map(spec["input_schema"])
      end
    end

    test "spec_for/1 finds a tool by name" do
      assert {:ok, spec} = ToolRegistry.spec_for("read_file")
      assert spec["name"] == "read_file"
    end

    test "spec_for/1 returns error for unknown tools" do
      assert {:error, :not_found} = ToolRegistry.spec_for("nonexistent_tool")
    end

    test "execute/2 routes to the correct tool" do
      assert {:error, _} = ToolRegistry.execute("read_file", %{"path" => "/nonexistent/path"})
    end

    test "execute/2 returns error for unknown tool names" do
      assert {:error, msg} = ToolRegistry.execute("not_a_tool", %{})
      assert msg =~ "Unknown tool"
    end
  end

  # ---------------------------------------------------------------------------
  # ReadFile
  # ---------------------------------------------------------------------------

  describe "ReadFile" do
    test "reads an existing file", %{dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      assert {:ok, content} = ReadFile.execute(%{"path" => path})
      assert content == "hello world"
    end

    test "returns error for nonexistent file" do
      assert {:error, msg} = ReadFile.execute(%{"path" => "/nonexistent/file.txt"})
      assert msg =~ "Cannot read"
    end
  end

  # ---------------------------------------------------------------------------
  # WriteFile
  # ---------------------------------------------------------------------------

  describe "WriteFile" do
    test "writes content to a new file", %{dir: dir} do
      path = Path.join(dir, "out.txt")
      assert {:ok, msg} = WriteFile.execute(%{"path" => path, "content" => "new content"})
      assert msg =~ "Wrote"
      assert File.read!(path) == "new content"
    end

    test "creates parent directories as needed", %{dir: dir} do
      path = Path.join([dir, "nested", "deep", "file.txt"])
      assert {:ok, _} = WriteFile.execute(%{"path" => path, "content" => "deep"})
      assert File.read!(path) == "deep"
    end

    test "overwrites existing file", %{dir: dir} do
      path = Path.join(dir, "existing.txt")
      File.write!(path, "old")
      assert {:ok, _} = WriteFile.execute(%{"path" => path, "content" => "new"})
      assert File.read!(path) == "new"
    end
  end

  # ---------------------------------------------------------------------------
  # EditFile
  # ---------------------------------------------------------------------------

  describe "EditFile" do
    test "replaces unique string in file", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "hello world\nfoo bar\n")

      assert {:ok, msg} =
               EditFile.execute(%{
                 "path" => path,
                 "old_string" => "foo bar",
                 "new_string" => "baz qux"
               })

      assert msg =~ "Replaced"
      assert File.read!(path) == "hello world\nbaz qux\n"
    end

    test "errors when string not found", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "hello world")

      assert {:error, msg} =
               EditFile.execute(%{"path" => path, "old_string" => "xyz", "new_string" => "abc"})

      assert msg =~ "not found"
    end

    test "errors when string is not unique", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "foo\nfoo\n")

      assert {:error, msg} =
               EditFile.execute(%{"path" => path, "old_string" => "foo", "new_string" => "bar"})

      assert msg =~ "2 times"
    end
  end

  # ---------------------------------------------------------------------------
  # Bash
  # ---------------------------------------------------------------------------

  describe "Bash" do
    test "runs a simple command and returns stdout" do
      assert {:ok, output} = Bash.execute(%{"command" => "echo hello"})
      assert String.trim(output) == "hello"
    end

    test "returns error tuple for non-zero exit code" do
      assert {:error, msg} = Bash.execute(%{"command" => "exit 1"})
      assert msg =~ "Exit code 1"
    end

    test "captures stderr in output" do
      assert {:error, msg} = Bash.execute(%{"command" => "ls /nonexistent_path_xyz 2>&1; exit 1"})
      assert is_binary(msg)
    end
  end

  # ---------------------------------------------------------------------------
  # Glob
  # ---------------------------------------------------------------------------

  describe "Glob" do
    test "finds files matching a pattern", %{dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "")
      File.write!(Path.join(dir, "b.ex"), "")
      File.write!(Path.join(dir, "c.txt"), "")

      assert {:ok, output} = Glob.execute(%{"pattern" => "*.ex", "base" => dir})
      assert output =~ "a.ex"
      assert output =~ "b.ex"
      refute output =~ "c.txt"
    end

    test "returns message when no files match", %{dir: dir} do
      assert {:ok, output} = Glob.execute(%{"pattern" => "*.nonexistent", "base" => dir})
      assert output =~ "No files matched"
    end
  end

  # ---------------------------------------------------------------------------
  # Ls
  # ---------------------------------------------------------------------------

  describe "Ls" do
    test "lists directory contents", %{dir: dir} do
      File.write!(Path.join(dir, "file.txt"), "content")
      File.mkdir_p!(Path.join(dir, "subdir"))

      assert {:ok, output} = Ls.execute(%{"path" => dir})
      assert output =~ "file.txt"
      assert output =~ "subdir/"
    end

    test "returns error for nonexistent directory" do
      assert {:error, msg} = Ls.execute(%{"path" => "/nonexistent_xyz"})
      assert msg =~ "Cannot list"
    end
  end
end
