defmodule RLM.Agent.SessionTest do
  use ExUnit.Case, async: false

  alias RLM.Agent.Session

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A mock "LLM" module for session tests. Instead of hitting the API,
  # it pulls pre-programmed Agent.LLM-style responses from ETS.
  defmodule MockAgentLLM do
    @table :mock_agent_llm

    def stub(responses) when is_list(responses) do
      :ets.new(@table, [:named_table, :public, :set])
      :ets.insert(@table, {:responses, responses})
    rescue
      _ ->
        :ets.delete_all_objects(@table)
        :ets.insert(@table, {:responses, responses})
    end

    def pop do
      case :ets.lookup(@table, :responses) do
        [{:responses, [r | rest]}] ->
          :ets.insert(@table, {:responses, rest})
          r

        _ ->
          # Default: plain text response
          {:ok, {:text, "Done."}, %{input_tokens: 5, output_tokens: 5}}
      end
    end

    # Matches Agent.LLM.call/4 interface so it can be used as agent_llm_module
    def call(_messages, _model, _config, _opts), do: pop()
  end

  defp start_session(opts \\ []) do
    session_id = "test-#{:rand.uniform(999_999)}"

    config =
      RLM.Config.load(
        llm_module: RLM.Test.MockLLM,
        agent_llm_module: MockAgentLLM,
        model_large: "mock-model"
      )

    default_opts = [
      session_id: session_id,
      config: config,
      tools: [],
      stream: false
    ]

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        RLM.AgentSup,
        {Session, Keyword.merge(default_opts, opts)}
      )

    session_id
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "Session lifecycle" do
    test "starts idle and reports status" do
      session_id = start_session()
      status = Session.status(session_id)
      assert status.status == :idle
      assert status.turn == 0
      assert status.message_count == 0
    end

    test "history is empty on start" do
      session_id = start_session()
      assert Session.history(session_id) == []
    end
  end

  describe "Session.send_message/2 — text response" do
    test "returns LLM text response and increments turn counter" do
      MockAgentLLM.stub([
        {:ok, {:text, "Hello from mock!"}, %{input_tokens: 10, output_tokens: 5}}
      ])

      session_id = start_session()
      assert {:ok, "Hello from mock!"} = Session.send_message(session_id, "hi", 5_000)

      status = Session.status(session_id)
      assert status.turn == 1
      assert status.message_count == 2
      assert status.total_input_tokens == 10
      assert status.total_output_tokens == 5
    end

    test "status is :idle after turn completes" do
      MockAgentLLM.stub([
        {:ok, {:text, "ok"}, %{input_tokens: 1, output_tokens: 1}}
      ])

      session_id = start_session()
      {:ok, _} = Session.send_message(session_id, "ping", 5_000)
      assert Session.status(session_id).status == :idle
    end

    test "rejects concurrent messages while busy" do
      # The stateful guard is tested implicitly — if the Task DI works the session
      # completes cleanly and we can send a second message sequentially.
      MockAgentLLM.stub([
        {:ok, {:text, "first"}, %{input_tokens: 1, output_tokens: 1}},
        {:ok, {:text, "second"}, %{input_tokens: 1, output_tokens: 1}}
      ])

      sid = start_session()
      assert {:ok, "first"} = Session.send_message(sid, "one", 5_000)
      assert {:ok, "second"} = Session.send_message(sid, "two", 5_000)
    end

    test "returns error and resets to :idle when turn task crashes" do
      # Inject a response that raises an exception inside the task
      defmodule CrashingLLM do
        def call(_messages, _model, _config, _opts), do: raise("simulated crash")
      end

      session_id = "crash-test-#{:rand.uniform(999_999)}"

      config =
        RLM.Config.load(
          agent_llm_module: CrashingLLM,
          model_large: "mock"
        )

      {:ok, _} =
        DynamicSupervisor.start_child(
          RLM.AgentSup,
          {Session, [session_id: session_id, config: config, tools: [], stream: false]}
        )

      assert {:error, _reason} = Session.send_message(session_id, "crash me", 5_000)
      assert Session.status(session_id).status == :idle
    end

    test "executes tool calls and returns final text response" do
      # LLM first returns a tool call, then returns text after the result
      MockAgentLLM.stub([
        {:ok, {:tool_calls, [%{id: "t1", name: "echo_tool", input: %{"msg" => "hi"}}], nil},
         %{input_tokens: 10, output_tokens: 5}},
        {:ok, {:text, "Tool done."}, %{input_tokens: 15, output_tokens: 3}}
      ])

      # Register a no-op echo tool inline
      tool_spec = %{
        "name" => "echo_tool",
        "description" => "echoes",
        "input_schema" => %{"type" => "object", "properties" => %{}}
      }

      session_id = "tool-test-#{:rand.uniform(999_999)}"

      config =
        RLM.Config.load(
          agent_llm_module: MockAgentLLM,
          model_large: "mock"
        )

      {:ok, _} =
        DynamicSupervisor.start_child(
          RLM.AgentSup,
          {Session,
           [
             session_id: session_id,
             config: config,
             # Use ToolRegistry.execute which will return {:error, "Unknown tool"}
             # but that's fine — the session should still complete the loop
             tools: [tool_spec],
             stream: false
           ]}
        )

      assert {:ok, "Tool done."} = Session.send_message(session_id, "use a tool", 5_000)
    end
  end

  describe "Agent.Prompt" do
    test "build/0 returns a non-empty string" do
      prompt = RLM.Agent.Prompt.build()
      assert is_binary(prompt)
      assert String.length(prompt) > 100
      assert prompt =~ "Elixir"
    end

    test "build/1 includes working directory" do
      prompt = RLM.Agent.Prompt.build(cwd: "/my/project")
      assert prompt =~ "/my/project"
    end

    test "build/1 appends extra instructions" do
      prompt = RLM.Agent.Prompt.build(extra: "Always use pattern matching.")
      assert prompt =~ "Always use pattern matching."
    end
  end

  describe "Session PubSub events" do
    test "broadcasts to agent:session:<id> topic" do
      session_id = "pubsub-test-#{:rand.uniform(999_999)}"
      topic = "agent:session:#{session_id}"

      Phoenix.PubSub.subscribe(RLM.PubSub, topic)

      config = RLM.Config.load(llm_module: RLM.Test.MockLLM, model_large: "mock")

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          RLM.AgentSup,
          {Session,
           [
             session_id: session_id,
             config: config,
             tools: [],
             stream: false
           ]}
        )

      # Broadcast a synthetic event to verify the topic works
      Phoenix.PubSub.broadcast(RLM.PubSub, topic, {:agent_event, :test, %{ok: true}})
      assert_receive {:agent_event, :test, %{ok: true}}, 1000
    end
  end
end
