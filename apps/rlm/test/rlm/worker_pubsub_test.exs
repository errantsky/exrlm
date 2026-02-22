defmodule RLM.WorkerPubSubTest do
  use ExUnit.Case, async: false

  alias RLM.Test.MockLLM

  setup do
    Phoenix.PubSub.subscribe(RLM.PubSub, "rlm:runs")
    :ok
  end

  describe "one-shot mode PubSub events" do
    test "emits node:start and node:stop events" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :pub_test")
      ])

      {:ok, :pub_test, run_id} = RLM.run("test", "test", llm_module: MockLLM)

      # Collect all messages for this run
      events = collect_events(run_id)
      event_types = Enum.map(events, & &1.event)

      assert [:rlm, :node, :start] in event_types
      assert [:rlm, :node, :stop] in event_types
      assert [:rlm, :iteration, :start] in event_types
      assert [:rlm, :iteration, :stop] in event_types
    end
  end

  describe "keep_alive mode PubSub events" do
    test "emits turn:complete instead of node:stop" do
      MockLLM.program_responses([
        MockLLM.mock_response("final_answer = :ka_pub")
      ])

      span_id = RLM.Span.generate_id()
      run_id = RLM.Span.generate_run_id()
      Phoenix.PubSub.subscribe(RLM.PubSub, "rlm:run:#{run_id}")

      config = RLM.Config.load(llm_module: MockLLM)

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          RLM.WorkerSup,
          {RLM.Worker,
           [
             span_id: span_id,
             run_id: run_id,
             config: config,
             keep_alive: true
           ]}
        )

      via = {:via, Registry, {RLM.Registry, {:worker, span_id}}}
      {:ok, :ka_pub} = GenServer.call(via, {:send_message, "test turn"}, 5000)

      events = collect_events(run_id)
      event_types = Enum.map(events, & &1.event)

      assert [:rlm, :turn, :complete] in event_types
      refute [:rlm, :node, :stop] in event_types
    end
  end

  defp collect_events(run_id) do
    collect_events_acc(run_id, [])
  end

  defp collect_events_acc(run_id, acc) do
    receive do
      %{event: _event, metadata: %{run_id: ^run_id}} = msg ->
        collect_events_acc(run_id, [msg | acc])

      %{event: _event} ->
        # Different run_id, skip but keep draining
        collect_events_acc(run_id, acc)
    after
      200 ->
        Enum.reverse(acc)
    end
  end
end
