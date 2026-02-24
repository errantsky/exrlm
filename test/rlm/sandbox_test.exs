defmodule RLM.SandboxTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "rlm_sandbox_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp eval_in_sandbox(code, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")

    RLM.Eval.run(code, [],
      timeout: 10_000,
      worker_pid: nil,
      bindings_info: [],
      cwd: cwd
    )
  end

  describe "tool functions from inside eval" do
    test "read_file works", %{dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "sandbox content")

      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|{:ok, content} = read_file("#{path}")\nIO.puts(content)|)

      assert stdout =~ "sandbox content"
    end

    test "bash works", %{dir: dir} do
      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|{:ok, out} = bash("echo hello")\nIO.puts(out)|, cwd: dir)

      assert stdout =~ "hello"
    end

    test "bash uses cwd from process dictionary", %{dir: dir} do
      File.write!(Path.join(dir, "marker.txt"), "found")

      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|{:ok, out} = bash("ls")\nIO.puts(out)|, cwd: dir)

      assert stdout =~ "marker.txt"
    end

    test "ls uses cwd from process dictionary", %{dir: dir} do
      File.write!(Path.join(dir, "file_a.txt"), "a")
      File.mkdir_p!(Path.join(dir, "sub"))

      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|{:ok, out} = ls()\nIO.puts(out)|, cwd: dir)

      assert stdout =~ "file_a.txt"
      assert stdout =~ "sub/"
    end

    test "rg searches in cwd by default", %{dir: dir} do
      File.write!(Path.join(dir, "search.txt"), "findme line\nother line\n")

      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|{:ok, out} = rg("findme")\nIO.puts(out)|, cwd: dir)

      assert stdout =~ "findme"
    end

    test "find_files uses cwd as base", %{dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "")
      File.write!(Path.join(dir, "b.txt"), "")

      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|{:ok, out} = find_files("*.ex")\nIO.puts(out)|, cwd: dir)

      assert stdout =~ "a.ex"
      refute stdout =~ "b.txt"
    end

    test "grep is the in-memory string search (not filesystem)", %{dir: _dir} do
      # grep/2 from RLM.Helpers does in-memory pattern matching on strings
      {:ok, stdout, _, _} =
        eval_in_sandbox("""
        results = grep("hello", "hello world\\ngoodbye world")
        IO.inspect(results)
        """)

      assert stdout =~ "{1, \"hello world\"}"
    end

    test "list_tools returns formatted tool descriptions" do
      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|IO.puts(list_tools())|)

      assert stdout =~ "Available tools:"
      assert stdout =~ "read_file"
      assert stdout =~ "bash"
    end

    test "tool_help returns description for known tool" do
      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|IO.puts(tool_help("bash"))|)

      assert stdout =~ "bash"
      assert stdout =~ "command"
    end

    test "tool_help returns error for unknown tool" do
      {:ok, stdout, _, _} =
        eval_in_sandbox(~s|IO.puts(tool_help("nonexistent"))|)

      assert stdout =~ "Unknown tool"
    end

    test "write_file and read_file round-trip", %{dir: dir} do
      path = Path.join(dir, "round_trip.txt")

      {:ok, stdout, _, _} =
        eval_in_sandbox("""
        {:ok, _} = write_file("#{path}", "round trip data")
        {:ok, content} = read_file("#{path}")
        IO.puts(content)
        """)

      assert stdout =~ "round trip data"
    end

    test "edit_file modifies file content", %{dir: dir} do
      path = Path.join(dir, "editable.txt")
      File.write!(path, "old content here")

      {:ok, _stdout, _, _} =
        eval_in_sandbox("""
        {:ok, _} = edit_file("#{path}", "old content", "new content")
        """)

      assert File.read!(path) == "new content here"
    end

    test "relative paths resolve against cwd", %{dir: dir} do
      File.write!(Path.join(dir, "relative.txt"), "relative content")

      {:ok, stdout, _, _} =
        eval_in_sandbox(
          ~s|{:ok, content} = read_file("relative.txt")\nIO.puts(content)|,
          cwd: dir
        )

      assert stdout =~ "relative content"
    end
  end
end
