defmodule RLM.Replay do
  @moduledoc """
  Replay a previously recorded RLM run.

  Replays use the recorded LLM responses but re-execute all eval'd code.
  This verifies that the same code still works against the current environment.

  ## Options

    * `:patch` — `%{iteration => code}` map. At the specified iteration, the
      patched code replaces the LLM's code before eval. The LLM response is
      still consumed from the tape (to maintain iteration alignment).
    * `:config` — config overrides applied to the replay run
  """

  @spec replay(String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def replay(run_id, opts \\ []) do
    patches = Keyword.get(opts, :patch, %{})
    config_overrides = Keyword.get(opts, :config, [])

    with {:ok, tape} <- RLM.Replay.Tape.from_events(run_id) do
      config =
        RLM.Config.load(
          Keyword.merge(config_overrides,
            llm_module: RLM.Replay.LLM,
            enable_replay_recording: false
          )
        )

      # Extract original context and query from the tape
      context = tape.context || ""
      query = tape.query || context

      replay_run_id = RLM.Span.generate_run_id()
      span_id = RLM.Span.generate_id()

      run_opts = [run_id: replay_run_id, config: config]

      case DynamicSupervisor.start_child(RLM.RunSup, {RLM.Run, run_opts}) do
        {:ok, run_pid} ->
          worker_opts = [
            span_id: span_id,
            run_id: replay_run_id,
            context: context,
            query: query,
            config: config,
            depth: 0,
            model: config.model_large,
            caller: self(),
            replay_tape: tape,
            replay_patches: patches
          ]

          case RLM.Run.start_worker(run_pid, worker_opts) do
            {:ok, pid} ->
              ref = Process.monitor(pid)
              total_timeout = config.eval_timeout * 2

              receive do
                {:rlm_result, ^span_id, {:ok, answer}} ->
                  Process.demonitor(ref, [:flush])
                  {:ok, answer, replay_run_id}

                {:rlm_result, ^span_id, {:error, reason}} ->
                  Process.demonitor(ref, [:flush])
                  {:error, reason}

                {:DOWN, ^ref, :process, ^pid, :normal} ->
                  {:error, "Replay worker exited without result"}

                {:DOWN, ^ref, :process, ^pid, reason} ->
                  {:error, "Replay worker crashed: #{inspect(reason)}"}
              after
                total_timeout ->
                  Process.demonitor(ref, [:flush])
                  RLM.terminate_run(run_pid)
                  {:error, "Replay timed out after #{total_timeout}ms"}
              end

            {:error, reason} ->
              RLM.terminate_run(run_pid)
              {:error, "Failed to start replay worker: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to start replay run: #{inspect(reason)}"}
      end
    end
  end
end
