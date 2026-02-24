defmodule RLM.DirectQueryTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM
  import RLM.Test.Helpers

  @entity_schema %{
    "type" => "object",
    "properties" => %{
      "names" => %{"type" => "array", "items" => %{"type" => "string"}},
      "count" => %{"type" => "integer"}
    },
    "required" => ["names", "count"],
    "additionalProperties" => false
  }

  describe "lm_query with schema:" do
    test "returns parsed map through RLM.run" do
      # First response: parent code uses lm_query with schema:
      # Second response: the direct query LLM call returns structured JSON
      schema_json = Jason.encode!(@entity_schema)

      parent_code =
        MockLLM.mock_response("""
        schema = Jason.decode!(~s(#{String.replace(schema_json, "\"", "\\\"")}))
        {:ok, result} = lm_query("Extract names from: Alice and Bob", schema: schema)
        final_answer = result
        """)

      direct_response =
        MockLLM.mock_direct_response(%{"names" => ["Alice", "Bob"], "count" => 2}, @entity_schema)

      MockLLM.program_responses([parent_code, direct_response])

      assert {:ok, result, _run_id} =
               RLM.run("test context", "extract names", llm_module: MockLLM, max_depth: 3)

      assert result == %{"names" => ["Alice", "Bob"], "count" => 2}
    end

    test "works with model_size: :large" do
      label_schema = %{
        "type" => "object",
        "properties" => %{"label" => %{"type" => "string"}},
        "required" => ["label"],
        "additionalProperties" => false
      }

      parent_code =
        MockLLM.mock_response(
          ~s|{:ok, result} = lm_query("classify", schema: %{"type" => "object", "properties" => %{"label" => %{"type" => "string"}}, "required" => ["label"], "additionalProperties" => false}, model_size: :large)\nfinal_answer = result|
        )

      direct_response = MockLLM.mock_direct_response(%{"label" => "positive"}, label_schema)

      MockLLM.program_responses([parent_code, direct_response])

      assert {:ok, %{"label" => "positive"}, _run_id} =
               RLM.run("test", "classify", llm_module: MockLLM, max_depth: 3)
    end

    test "propagates LLM error" do
      parent_code =
        MockLLM.mock_response(
          ~s|result = lm_query("fail", schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false})\nfinal_answer = result|
        )

      MockLLM.program_responses([parent_code, {:error, "API rate limited"}])

      assert {:ok, {:error, "API rate limited"}, _run_id} =
               RLM.run("test", "fail test", llm_module: MockLLM, max_depth: 3)
    end

    test "returns error on invalid JSON response" do
      parent_code =
        MockLLM.mock_response(
          ~s|result = lm_query("bad json", schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false})\nfinal_answer = result|
        )

      # Program a non-JSON string as the direct query response
      MockLLM.program_responses([parent_code, "not valid json at all"])

      assert {:ok, {:error, msg}, _run_id} =
               RLM.run("test", "bad json test", llm_module: MockLLM, max_depth: 3)

      assert msg =~ "JSON decode failed"
    end
  end

  describe "mock_direct_response/2 validation" do
    test "raises on missing required key" do
      assert_raise ArgumentError, ~r/missing required key/, fn ->
        MockLLM.mock_direct_response(%{"count" => 1}, @entity_schema)
      end
    end

    test "raises on wrong type" do
      assert_raise ArgumentError, ~r/expected type string/, fn ->
        schema = %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}},
          "required" => ["name"],
          "additionalProperties" => false
        }

        MockLLM.mock_direct_response(%{"name" => 123}, schema)
      end
    end

    test "raises on unexpected keys" do
      assert_raise ArgumentError, ~r/unexpected keys/, fn ->
        schema = %{
          "type" => "object",
          "properties" => %{"a" => %{"type" => "string"}},
          "required" => ["a"],
          "additionalProperties" => false
        }

        MockLLM.mock_direct_response(%{"a" => "ok", "b" => "extra"}, schema)
      end
    end
  end

  describe "concurrency limits" do
    test "rejects direct query when max_concurrent_subcalls is 0" do
      config =
        RLM.Config.load(
          llm_module: MockLLM,
          max_concurrent_subcalls: 0,
          max_depth: 5,
          max_iterations: 5
        )

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()

      MockLLM.program_responses([
        MockLLM.mock_response("Process.sleep(200)\nfinal_answer = :done")
      ])

      %{run_pid: run_pid} = start_test_run(run_id: run_id, config: config)

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

      {:ok, pid} = RLM.Run.start_worker(run_pid, worker_opts)

      # Wait for eval to start
      Process.sleep(50)

      schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      result = GenServer.call(pid, {:direct_query, "test", :small, schema})
      assert {:error, msg} = result
      assert msg =~ "Max concurrent subcalls"

      receive do
        {:rlm_result, ^span_id, _} -> :ok
      after
        5000 -> flunk("Worker did not complete")
      end
    end
  end

  describe "parallel_query with schema:" do
    test "returns list of parsed maps" do
      schema = %{
        "type" => "object",
        "properties" => %{"sentiment" => %{"type" => "string"}},
        "required" => ["sentiment"],
        "additionalProperties" => false
      }

      schema_code = inspect(schema)

      parent_code =
        MockLLM.mock_response("""
        inputs = [
          {"Analyze: I love it", schema: #{schema_code}, model_size: :small},
          {"Analyze: I hate it", schema: #{schema_code}, model_size: :small}
        ]
        results = parallel_query(inputs)
        final_answer = results
        """)

      MockLLM.program_responses([
        parent_code,
        MockLLM.mock_direct_response(%{"sentiment" => "positive"}, schema),
        MockLLM.mock_direct_response(%{"sentiment" => "negative"}, schema)
      ])

      assert {:ok, results, _run_id} =
               RLM.run("test", "parallel schema", llm_module: MockLLM, max_depth: 3)

      assert [
               {:ok, %{"sentiment" => "positive"}},
               {:ok, %{"sentiment" => "negative"}}
             ] = results
    end
  end

  describe "telemetry events" do
    test "emits direct_query start and stop events" do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      handler_id = "test-direct-query-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:rlm, :direct_query, :start],
          [:rlm, :direct_query, :stop]
        ],
        handler,
        nil
      )

      schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"],
        "additionalProperties" => false
      }

      schema_code = inspect(schema)

      parent_code =
        MockLLM.mock_response(
          ~s|{:ok, r} = lm_query("test", schema: #{schema_code})\nfinal_answer = r|
        )

      MockLLM.program_responses([
        parent_code,
        MockLLM.mock_direct_response(%{"result" => "ok"}, schema)
      ])

      RLM.run("test", "telemetry test", llm_module: MockLLM, max_depth: 3)

      assert_receive {^ref, [:rlm, :direct_query, :start], _, metadata}, 5000
      assert metadata.query_id != nil
      assert metadata.span_id != nil

      assert_receive {^ref, [:rlm, :direct_query, :stop], _, metadata}, 5000
      assert metadata.query_id != nil
      assert metadata.status == :ok

      :telemetry.detach(handler_id)
    end
  end
end
