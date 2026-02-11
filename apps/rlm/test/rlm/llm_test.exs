defmodule RLM.LLMTest do
  use ExUnit.Case, async: true

  describe "extract_code/1" do
    test "extracts elixir code block" do
      response = """
      Here's the code:

      ```elixir
      final_answer = 42
      ```
      """

      assert {:ok, "final_answer = 42"} = RLM.LLM.extract_code(response)
    end

    test "extracts last code block when multiple exist" do
      response = """
      First attempt:
      ```elixir
      x = 1
      ```

      Better approach:
      ```elixir
      final_answer = 42
      ```
      """

      assert {:ok, "final_answer = 42"} = RLM.LLM.extract_code(response)
    end

    test "handles case-insensitive Elixir tag" do
      response = """
      ```Elixir
      final_answer = 42
      ```
      """

      assert {:ok, "final_answer = 42"} = RLM.LLM.extract_code(response)
    end

    test "returns error when no code block found" do
      assert {:error, :no_code_block} = RLM.LLM.extract_code("Just some text")
    end

    test "returns error for non-elixir code blocks" do
      response = """
      ```python
      print("hello")
      ```
      """

      assert {:error, :no_code_block} = RLM.LLM.extract_code(response)
    end

    test "handles multiline code" do
      response = """
      ```elixir
      x = 1
      y = 2
      final_answer = x + y
      ```
      """

      {:ok, code} = RLM.LLM.extract_code(response)
      assert code =~ "x = 1"
      assert code =~ "final_answer = x + y"
    end
  end
end
