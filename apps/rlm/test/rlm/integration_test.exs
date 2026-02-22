defmodule RLM.IntegrationTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM

  # The application starts the supervision tree automatically.
  # No manual setup needed.

  describe "telemetry events" do
    test "emits node start and stop events" do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      handler_id = "test-handler-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:rlm, :node, :start],
          [:rlm, :node, :stop],
          [:rlm, :iteration, :start],
          [:rlm, :iteration, :stop]
        ],
        handler,
        nil
      )

      MockLLM.program_responses(self(), [
        MockLLM.mock_response("final_answer = 42")
      ])

      RLM.run("test", "q", llm_module: MockLLM)

      assert_receive {^ref, [:rlm, :node, :start], _, metadata}, 5000
      assert metadata.depth == 0
      assert metadata.span_id != nil

      assert_receive {^ref, [:rlm, :iteration, :start], _, _}, 5000

      assert_receive {^ref, [:rlm, :iteration, :stop], measurements, metadata}, 5000
      assert measurements.duration_ms >= 0
      assert metadata.iteration == 0
      assert metadata.final_answer == 42

      assert_receive {^ref, [:rlm, :node, :stop], measurements, metadata}, 5000
      assert measurements.total_iterations == 1
      assert metadata.status == :ok

      :telemetry.detach(handler_id)
    end
  end

  describe "event log" do
    test "records execution trace" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("x = 1"),
        MockLLM.mock_response("final_answer = x + 1")
      ])

      config = RLM.Config.load(llm_module: MockLLM)
      run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test",
        query: "test query",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, _pid} = DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts})

      receive do
        {:rlm_result, ^span_id, {:ok, 2}} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end

      Process.sleep(100)

      tree = RLM.EventLog.get_tree(run_id)
      assert map_size(tree) == 1

      node = Map.get(tree, span_id)
      assert node.status == :ok
      assert node.depth == 0
      assert length(node.iterations) == 2
    end

    test "exports JSONL format" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("final_answer = \"done\"")
      ])

      config = RLM.Config.load(llm_module: MockLLM)
      run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      worker_opts = [
        span_id: span_id,
        run_id: run_id,
        context: "test",
        query: "test",
        config: config,
        depth: 0,
        model: config.model_large,
        caller: self()
      ]

      {:ok, _pid} = DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, worker_opts})

      receive do
        {:rlm_result, ^span_id, _} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end

      Process.sleep(100)

      jsonl = RLM.EventLog.to_jsonl(run_id)
      lines = String.split(jsonl, "\n", trim: true)
      assert length(lines) > 0

      for line <- lines do
        assert {:ok, _} = Jason.decode(line)
      end
    end
  end

  describe "subcall spawning" do
    test "child worker spawns and returns result to parent" do
      parent_code =
        MockLLM.mock_response(
          "{:ok, result} = lm_query(\"sub input\", model_size: :small)\nfinal_answer = \"parent got: \" <> result",
          "invoking sub-call"
        )

      MockLLM.program_responses(self(), [parent_code])

      assert {:ok, "parent got: default mock answer", _run_id} =
               RLM.run("parent context", "Test subcalls",
                 llm_module: MockLLM,
                 max_depth: 3
               )
    end
  end

  describe "direct query (schema mode)" do
    test "lm_query with schema: returns parsed map via RLM.run" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "answer" => %{"type" => "string"}
        },
        "required" => ["answer"],
        "additionalProperties" => false
      }

      schema_code = inspect(schema)

      parent_code =
        MockLLM.mock_response(
          "{:ok, result} = lm_query(\"What is 1+1?\", schema: #{schema_code})\nfinal_answer = result",
          "direct query with schema"
        )

      MockLLM.program_responses(self(), [
        parent_code,
        MockLLM.mock_direct_response(%{"answer" => "2"}, schema)
      ])

      assert {:ok, %{"answer" => "2"}, _run_id} =
               RLM.run("test", "schema query",
                 llm_module: MockLLM,
                 max_depth: 3
               )
    end
  end

  describe "sandbox helpers" do
    test "chunks helper is available in sandbox code" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response(
          "result = chunks(context, 5) |> Enum.to_list()\nfinal_answer = length(result)"
        )
      ])

      assert {:ok, 3, _} = RLM.run("hello world!!!", "chunk it", llm_module: MockLLM)
    end

    test "grep helper is available in sandbox code" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response(
          "matches = grep(\"hello\", context)\nfinal_answer = length(matches)"
        )
      ])

      assert {:ok, 2, _} =
               RLM.run("hello\nworld\nhello again", "grep it", llm_module: MockLLM)
    end

    test "preview helper is available in sandbox code" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("p = preview(context, 10)\nfinal_answer = p")
      ])

      assert {:ok, result, _} =
               RLM.run("a very long string here", "preview it", llm_module: MockLLM)

      assert is_binary(result)
    end

    test "list_bindings helper is available in sandbox code" do
      MockLLM.program_responses(self(), [
        MockLLM.mock_response("bindings = list_bindings()\nfinal_answer = length(bindings)")
      ])

      assert {:ok, count, _} = RLM.run("test", "list bindings", llm_module: MockLLM)
      assert count >= 3
    end
  end

  describe "config" do
    test "loads defaults" do
      config = RLM.Config.load()
      assert config.max_iterations == 25
      assert config.max_depth == 5
      assert config.truncation_head == 4000
      assert config.api_base_url == "https://api.anthropic.com"
      assert config.model_small =~ "haiku"
    end

    test "accepts overrides" do
      config = RLM.Config.load(max_iterations: 10, max_depth: 2)
      assert config.max_iterations == 10
      assert config.max_depth == 2
    end
  end
end
