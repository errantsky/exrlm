defmodule RLM.Test.Helpers do
  @moduledoc false

  @doc """
  Start a Run process for testing. Returns a map with run context.

  The Run is started under `RLM.RunSup` and provides the `run_pid`, `run_id`,
  and `config` needed to start Workers via `RLM.Run.start_worker/2`.

  ## Options

    * `:run_id` — override the run ID (default: generated)
    * `:config` — override the config (default: MockLLM config)
    * `:keep_alive` — whether the run supports keep-alive sessions (default: false)
  """
  def start_test_run(opts \\ []) do
    run_id = Keyword.get(opts, :run_id, RLM.Span.generate_run_id())

    config =
      Keyword.get(
        opts,
        :config,
        RLM.Config.load(llm_module: RLM.Test.MockLLM)
      )

    keep_alive = Keyword.get(opts, :keep_alive, false)
    run_opts = [run_id: run_id, config: config, keep_alive: keep_alive]
    {:ok, run_pid} = DynamicSupervisor.start_child(RLM.RunSup, {RLM.Run, run_opts})

    %{run_pid: run_pid, run_id: run_id, config: config}
  end
end
