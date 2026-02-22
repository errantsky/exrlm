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

  describe "extract_structured/1" do
    test "extracts valid JSON with reasoning and code" do
      json = Jason.encode!(%{"reasoning" => "thinking about it", "code" => "final_answer = 42"})

      assert {:ok, %{reasoning: "thinking about it", code: "final_answer = 42"}} =
               RLM.LLM.extract_structured(json)
    end

    test "handles empty code field" do
      json = Jason.encode!(%{"reasoning" => "still thinking", "code" => ""})

      assert {:ok, %{reasoning: "still thinking", code: ""}} =
               RLM.LLM.extract_structured(json)
    end

    test "handles code with special characters (newlines, quotes, backslashes)" do
      code = "x = \"hello\\nworld\"\nfinal_answer = x"
      json = Jason.encode!(%{"reasoning" => "test", "code" => code})

      assert {:ok, %{code: ^code}} = RLM.LLM.extract_structured(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = RLM.LLM.extract_structured("not json at all")
      assert msg =~ "JSON parse failed"
    end

    test "returns error for missing reasoning field" do
      json = Jason.encode!(%{"code" => "final_answer = 42"})

      assert {:error, "Missing required fields in structured response"} =
               RLM.LLM.extract_structured(json)
    end

    test "returns error for missing code field" do
      json = Jason.encode!(%{"reasoning" => "thinking"})

      assert {:error, "Missing required fields in structured response"} =
               RLM.LLM.extract_structured(json)
    end

    test "returns error for non-string field values" do
      json = Jason.encode!(%{"reasoning" => 123, "code" => "x = 1"})

      assert {:error, "Missing required fields in structured response"} =
               RLM.LLM.extract_structured(json)
    end
  end

  describe "response_schema/0" do
    test "returns a valid JSON schema with required fields" do
      schema = RLM.LLM.response_schema()
      assert schema["type"] == "object"
      assert "reasoning" in schema["required"]
      assert "code" in schema["required"]
      assert schema["additionalProperties"] == false
    end
  end
end
