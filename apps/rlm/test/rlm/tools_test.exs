defmodule RLM.ToolsTest do
  use ExUnit.Case, async: true

  alias RLM.Tools.{ReadFile, WriteFile, EditFile, Bash, Grep, Glob, Ls}

  # Unique temp dir per test, cleaned up on exit
  setup do
    dir = Path.join(System.tmp_dir!(), "rlm_tools_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ---------------------------------------------------------------------------
  # RLM.Tools.Registry
  # ---------------------------------------------------------------------------

  describe "Registry" do
    test "all/0 returns all tool modules" do
      tools = RLM.Tools.Registry.all()
      assert length(tools) == 7
      assert RLM.Tools.ReadFile in tools
      assert RLM.Tools.Bash in tools
    end

    test "list/0 returns {name, summary} tuples" do
      items = RLM.Tools.Registry.list()
      assert length(items) == 7

      for {name, summary} <- items do
        assert is_atom(name)
        assert is_binary(summary)
      end
    end

    test "doc/1 returns doc string for known tool" do
      doc = RLM.Tools.Registry.doc(:read_file)
      assert is_binary(doc)
      assert doc =~ "read_file"
    end

    test "doc/1 returns nil for unknown tool" do
      assert RLM.Tools.Registry.doc(:nonexistent) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # ReadFile
  # ---------------------------------------------------------------------------

  describe "ReadFile" do
    test "reads an existing file", %{dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      assert {:ok, content} = ReadFile.execute(path)
      assert content == "hello world"
    end

    test "returns error for nonexistent file" do
      assert {:error, msg} = ReadFile.execute("/nonexistent/file.txt")
      assert msg =~ "Cannot read"
    end

    test "truncates large files", %{dir: dir} do
      path = Path.join(dir, "big.txt")
      File.write!(path, String.duplicate("x", 150_000))

      assert {:ok, content} = ReadFile.execute(path)
      assert content =~ "truncated"
      assert byte_size(content) < 150_000
    end
  end

  # ---------------------------------------------------------------------------
  # WriteFile
  # ---------------------------------------------------------------------------

  describe "WriteFile" do
    test "writes content to a new file", %{dir: dir} do
      path = Path.join(dir, "out.txt")
      assert {:ok, msg} = WriteFile.execute(path, "new content")
      assert msg =~ "Wrote"
      assert File.read!(path) == "new content"
    end

    test "creates parent directories as needed", %{dir: dir} do
      path = Path.join([dir, "nested", "deep", "file.txt"])
      assert {:ok, _} = WriteFile.execute(path, "deep")
      assert File.read!(path) == "deep"
    end

    test "overwrites existing file", %{dir: dir} do
      path = Path.join(dir, "existing.txt")
      File.write!(path, "old")
      assert {:ok, _} = WriteFile.execute(path, "new")
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

      assert {:ok, msg} = EditFile.execute(path, "foo bar", "baz qux")
      assert msg =~ "Replaced"
      assert File.read!(path) == "hello world\nbaz qux\n"
    end

    test "errors when string not found", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "hello world")

      assert {:error, msg} = EditFile.execute(path, "xyz", "abc")
      assert msg =~ "not found"
    end

    test "errors when string is not unique", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "foo\nfoo\n")

      assert {:error, msg} = EditFile.execute(path, "foo", "bar")
      assert msg =~ "2 times"
    end

    test "insert at beginning with empty old_string", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "existing content")

      assert {:ok, msg} = EditFile.execute(path, "", "HEADER\n")
      assert msg =~ "Inserted"
      assert File.read!(path) == "HEADER\nexisting content"
    end
  end

  # ---------------------------------------------------------------------------
  # Bash
  # ---------------------------------------------------------------------------

  describe "Bash" do
    test "runs a simple command and returns stdout" do
      assert {:ok, output} = Bash.execute("echo hello")
      assert String.trim(output) == "hello"
    end

    test "returns error tuple for non-zero exit code" do
      assert {:error, msg} = Bash.execute("exit 1")
      assert msg =~ "Exit code 1"
    end

    test "respects cwd option", %{dir: dir} do
      File.write!(Path.join(dir, "marker.txt"), "here")
      assert {:ok, output} = Bash.execute("ls", cwd: dir)
      assert output =~ "marker.txt"
    end

    test "caps timeout at max ceiling" do
      assert {:ok, _} = Bash.execute("echo ok", timeout_ms: 999_999_999)
    end
  end

  # ---------------------------------------------------------------------------
  # Grep
  # ---------------------------------------------------------------------------

  describe "Grep" do
    test "finds pattern in files", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "hello world\nfoo bar\n")
      assert {:ok, output} = Grep.execute("hello", path: dir)
      assert output =~ "hello"
    end

    test "returns no matches message when pattern absent", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "nothing here")
      assert {:ok, msg} = Grep.execute("xyz_not_present", path: dir)
      assert msg =~ "No matches found"
    end

    test "truncates output at max_results", %{dir: dir} do
      content = Enum.map_join(1..300, "\n", fn i -> "match_line_#{i}" end)
      File.write!(Path.join(dir, "big.txt"), content)

      assert {:ok, output} = Grep.execute("match_line", path: dir)
      lines = String.split(output, "\n", trim: true)
      assert length(lines) <= 201
      assert output =~ "truncated"
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

      assert {:ok, output} = Glob.execute("*.ex", base: dir)
      assert output =~ "a.ex"
      assert output =~ "b.ex"
      refute output =~ "c.txt"
    end

    test "returns message when no files match", %{dir: dir} do
      assert {:ok, output} = Glob.execute("*.nonexistent", base: dir)
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

      assert {:ok, output} = Ls.execute(dir)
      assert output =~ "file.txt"
      assert output =~ "subdir/"
    end

    test "returns error for nonexistent directory" do
      assert {:error, msg} = Ls.execute("/nonexistent_xyz")
      assert msg =~ "Cannot list"
    end
  end

  # ---------------------------------------------------------------------------
  # RLM.Tool behaviour
  # ---------------------------------------------------------------------------

  describe "Tool behaviour" do
    test "each tool has a name and doc" do
      for mod <- RLM.Tools.Registry.all() do
        assert is_atom(mod.name())
        assert is_binary(mod.doc())
        assert String.length(mod.doc()) > 10
      end
    end
  end
end
