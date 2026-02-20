defmodule RLM.SandboxTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "rlm_sandbox_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # ---------------------------------------------------------------------------
  # Tool discovery
  # ---------------------------------------------------------------------------

  describe "list_tools/0" do
    test "returns formatted string of tool names and summaries" do
      result = RLM.Sandbox.list_tools()
      assert is_binary(result)
      assert result =~ "read_file"
      assert result =~ "bash"
      assert result =~ "grep_files"
    end
  end

  describe "tool_help/1" do
    test "returns doc string for known tool" do
      doc = RLM.Sandbox.tool_help(:read_file)
      assert is_binary(doc)
      assert doc =~ "read_file"
      assert doc =~ "Examples"
    end

    test "returns message for unknown tool" do
      msg = RLM.Sandbox.tool_help(:nonexistent)
      assert msg =~ "Unknown tool"
      assert msg =~ "list_tools()"
    end
  end

  # ---------------------------------------------------------------------------
  # File tool wrappers (unwrap! behaviour)
  # ---------------------------------------------------------------------------

  describe "read_file/1" do
    test "returns file content directly", %{dir: dir} do
      path = Path.join(dir, "test.txt")
      File.write!(path, "hello from sandbox")

      content = RLM.Sandbox.read_file(path)
      assert content == "hello from sandbox"
    end

    test "raises on error" do
      assert_raise RuntimeError, ~r/Cannot read/, fn ->
        RLM.Sandbox.read_file("/nonexistent/path.txt")
      end
    end
  end

  describe "write_file/2" do
    test "writes and returns confirmation", %{dir: dir} do
      path = Path.join(dir, "out.txt")
      result = RLM.Sandbox.write_file(path, "sandbox content")
      assert result =~ "Wrote"
      assert File.read!(path) == "sandbox content"
    end
  end

  describe "edit_file/3" do
    test "replaces string and returns confirmation", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "old value")

      result = RLM.Sandbox.edit_file(path, "old value", "new value")
      assert result =~ "Replaced"
      assert File.read!(path) == "new value"
    end

    test "raises when string not found", %{dir: dir} do
      path = Path.join(dir, "edit.txt")
      File.write!(path, "hello")

      assert_raise RuntimeError, ~r/not found/, fn ->
        RLM.Sandbox.edit_file(path, "xyz", "abc")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Shell/search wrappers
  # ---------------------------------------------------------------------------

  describe "bash/1" do
    test "returns stdout directly" do
      output = RLM.Sandbox.bash("echo sandbox")
      assert String.trim(output) == "sandbox"
    end

    test "raises on non-zero exit" do
      assert_raise RuntimeError, ~r/Exit code/, fn ->
        RLM.Sandbox.bash("exit 42")
      end
    end
  end

  describe "ls/1" do
    test "returns directory listing", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "")
      output = RLM.Sandbox.ls(dir)
      assert output =~ "a.txt"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: sandbox functions in eval context
  # ---------------------------------------------------------------------------

  describe "eval integration" do
    test "read_file works through RLM.Eval.run", %{dir: dir} do
      path = Path.join(dir, "data.txt")
      File.write!(path, "eval test content")

      code = ~s[result = read_file("#{path}")\nIO.puts(result)]

      {:ok, stdout, _value, _bindings} =
        RLM.Eval.run(code, [], timeout: 5_000)

      assert stdout =~ "eval test content"
    end

    test "list_tools works through RLM.Eval.run" do
      code = "IO.puts(list_tools())"

      {:ok, stdout, _value, _bindings} =
        RLM.Eval.run(code, [], timeout: 5_000)

      assert stdout =~ "read_file"
      assert stdout =~ "bash"
    end

    test "tool_help works through RLM.Eval.run" do
      code = "IO.puts(tool_help(:bash))"

      {:ok, stdout, _value, _bindings} =
        RLM.Eval.run(code, [], timeout: 5_000)

      assert stdout =~ "bash"
      assert stdout =~ "timeout_ms"
    end
  end
end
