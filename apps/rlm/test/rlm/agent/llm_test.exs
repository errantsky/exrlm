defmodule RLM.Agent.LLMTest do
  use ExUnit.Case, async: false

  alias RLM.Agent.Message

  # ---------------------------------------------------------------------------
  # Agent.Message — pure functions, fully testable
  # ---------------------------------------------------------------------------

  describe "Message.user/1 and Message.assistant/1" do
    test "creates correctly typed maps" do
      assert %{role: :user, content: "hello"} = Message.user("hello")
      assert %{role: :assistant, content: "hi"} = Message.assistant("hi")
      assert %{role: :system, content: "you are"} = Message.system("you are")
    end
  end

  describe "Message.to_api_map/1" do
    test "serialises text messages to string role" do
      msg = Message.user("hi")
      assert %{"role" => "user", "content" => "hi"} = Message.to_api_map(msg)
    end

    test "serialises messages with block content" do
      blocks = [%{"type" => "text", "text" => "x"}]
      msg = Message.assistant_from_blocks(blocks)
      assert %{"role" => "assistant", "content" => ^blocks} = Message.to_api_map(msg)
    end
  end

  describe "Message.tool_result/3" do
    test "builds a tool_result user message" do
      msg = Message.tool_result("id-1", "file contents")
      assert msg.role == :user
      assert is_list(msg.content)
      [block] = msg.content
      assert block["type"] == "tool_result"
      assert block["tool_use_id"] == "id-1"
      assert block["content"] == "file contents"
      assert block["is_error"] == false
    end

    test "marks error results" do
      msg = Message.tool_result("id-2", "permission denied", true)
      [block] = msg.content
      assert block["is_error"] == true
    end

    test "stringifies non-binary content" do
      msg = Message.tool_result("id-3", {:error, :not_found})
      [block] = msg.content
      assert is_binary(block["content"])
    end
  end

  describe "Message.tool_results/1" do
    test "batches multiple tool results into one user message" do
      msg =
        Message.tool_results([
          %{tool_use_id: "id-1", content: "result A"},
          %{tool_use_id: "id-2", content: "result B", is_error: true}
        ])

      assert msg.role == :user
      assert length(msg.content) == 2
      [a, b] = msg.content
      assert a["tool_use_id"] == "id-1"
      assert b["is_error"] == true
    end
  end

  describe "Message.parse_response_content/1" do
    test "extracts text from plain text blocks" do
      blocks = [%{"type" => "text", "text" => "Hello!"}]
      result = Message.parse_response_content(blocks)
      assert result.text == "Hello!"
      assert result.tool_calls == []
    end

    test "extracts tool_use blocks" do
      blocks = [
        %{"type" => "text", "text" => "Let me read that file."},
        %{
          "type" => "tool_use",
          "id" => "tu-1",
          "name" => "read_file",
          "input" => %{"path" => "/tmp/foo.txt"}
        }
      ]

      result = Message.parse_response_content(blocks)
      assert result.text == "Let me read that file."
      assert length(result.tool_calls) == 1
      [call] = result.tool_calls
      assert call.id == "tu-1"
      assert call.name == "read_file"
      assert call.input == %{"path" => "/tmp/foo.txt"}
    end

    test "handles empty content gracefully" do
      result = Message.parse_response_content([])
      assert result.text == nil
      assert result.tool_calls == []
    end
  end

  # ---------------------------------------------------------------------------
  # Agent.LLM — live API tests (excluded by default, need CLAUDE_API_KEY)
  # ---------------------------------------------------------------------------

  @moduletag :live_api

  describe "Agent.LLM.call/4 — live API" do
    test "returns text response without tools" do
      config = RLM.Config.load()
      messages = [Message.user("Reply with exactly the word: PONG")]

      assert {:ok, {:text, text}, usage} =
               RLM.Agent.LLM.call(messages, config.model_small, config)

      assert String.contains?(text, "PONG")
      assert usage.input_tokens > 0
      assert usage.output_tokens > 0
    end

    test "calls a tool when tools are provided" do
      config = RLM.Config.load()

      tool = %{
        "name" => "echo",
        "description" => "Echoes the input back.",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "message" => %{"type" => "string", "description" => "Text to echo"}
          },
          "required" => ["message"]
        }
      }

      messages = [Message.user("Please call the echo tool with message 'hello world'.")]

      assert {:ok, {:tool_calls, calls, _text}, _usage} =
               RLM.Agent.LLM.call(messages, config.model_small, config, tools: [tool])

      assert [%{name: "echo", input: %{"message" => _}}] = calls
    end

    test "streams text deltas to on_chunk callback" do
      config = RLM.Config.load()
      messages = [Message.user("Count to 3, one number per word.")]

      ref = make_ref()
      parent = self()

      on_chunk = fn text ->
        send(parent, {ref, :chunk, text})
      end

      assert {:ok, {:text, full_text}, _usage} =
               RLM.Agent.LLM.call(messages, config.model_small, config,
                 stream: true,
                 on_chunk: on_chunk
               )

      chunks =
        Enum.reduce_while(Stream.repeatedly(fn -> nil end), [], fn _, acc ->
          receive do
            {^ref, :chunk, text} -> {:cont, [text | acc]}
          after
            100 -> {:halt, acc}
          end
        end)

      # Streaming should deliver some chunks
      assert length(chunks) > 0
      # Full text should be assembled correctly
      assert String.length(full_text) > 0
    end
  end
end
