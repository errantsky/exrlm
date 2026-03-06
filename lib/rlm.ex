defmodule RLM do
  use Boundary,
    deps: [],
    exports: [
      Config,
      Run,
      Worker,
      EventLog,
      TraceStore,
      Helpers,
      Span,
      IEx,
      Node,
      Replay,
      Replay.Tape,
      Replay.LLM,
      Replay.FallbackLLM,
      Telemetry,
      Telemetry.PubSub,
      Tool,
      ToolRegistry,
      Skill,
      Skill.Prompt,
      SkillRegistry
    ]

  @moduledoc """
  Public API for the Recursive Language Model engine.

  ## One-shot queries

      {:ok, answer, run_id} = RLM.run("Your long input text...", "Summarize this")

  ## Interactive sessions

      {:ok, session_id} = RLM.start_session(cwd: ".")
      {:ok, answer} = RLM.send_message(session_id, "List files in current directory")
      {:ok, answer2} = RLM.send_message(session_id, "Now read the README")
      history = RLM.history(session_id)
  """

  # ---------------------------------------------------------------------------
  # One-shot API
  # ---------------------------------------------------------------------------

  @spec run(String.t(), String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def run(context, query, opts \\ []) when is_binary(context) and is_binary(query) do
    config = RLM.Config.load(opts)
    span_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()
    # Generous overall timeout: two full eval cycles worth
    total_timeout = config.eval_timeout * 2

    {skill_catalog, activated_skills} = resolve_skills(opts)

    run_opts = [run_id: run_id, config: config]

    case DynamicSupervisor.start_child(RLM.RunSup, {RLM.Run, run_opts}) do
      {:ok, run_pid} ->
        worker_opts = [
          span_id: span_id,
          run_id: run_id,
          context: context,
          query: query,
          config: config,
          depth: 0,
          model_key: :large,
          caller: self(),
          skill_catalog: skill_catalog,
          activated_skills: activated_skills
        ]

        case RLM.Run.start_worker(run_pid, worker_opts) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            receive do
              {:rlm_result, ^span_id, {:ok, answer}} ->
                Process.demonitor(ref, [:flush])
                {:ok, answer, run_id}

              {:rlm_result, ^span_id, {:error, reason}} ->
                Process.demonitor(ref, [:flush])
                {:error, reason}

              {:DOWN, ^ref, :process, ^pid, :normal} ->
                {:error, "Worker exited normally without sending a result"}

              {:DOWN, ^ref, :process, ^pid, reason} ->
                {:error, "Worker crashed: #{inspect(reason)}"}
            after
              total_timeout ->
                Process.demonitor(ref, [:flush])
                # Kill the entire run (all workers, eval tasks)
                terminate_run(run_pid)
                {:error, "RLM.run timed out after #{total_timeout}ms"}
            end

          {:error, reason} ->
            terminate_run(run_pid)
            {:error, "Failed to start worker: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to start run: #{inspect(reason)}"}
    end
  end

  @spec run_async(String.t(), String.t(), keyword()) :: {:ok, String.t(), pid()}
  def run_async(context, query, opts \\ []) do
    config = RLM.Config.load(opts)
    span_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()

    {skill_catalog, activated_skills} = resolve_skills(opts)

    run_opts = [run_id: run_id, config: config]

    case DynamicSupervisor.start_child(RLM.RunSup, {RLM.Run, run_opts}) do
      {:ok, run_pid} ->
        worker_opts = [
          span_id: span_id,
          run_id: run_id,
          context: context,
          query: query,
          config: config,
          depth: 0,
          model_key: :large,
          caller: self(),
          skill_catalog: skill_catalog,
          activated_skills: activated_skills
        ]

        case RLM.Run.start_worker(run_pid, worker_opts) do
          {:ok, pid} ->
            {:ok, run_id, pid}

          {:error, reason} ->
            terminate_run(run_pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Interactive Session API
  # ---------------------------------------------------------------------------

  @doc """
  Start an interactive keep-alive session.

  The Worker starts idle and waits for `send_message/3` calls.
  Bindings persist across turns.

  Options:
    - `:cwd` — working directory for tools (default: current dir)
    - `:model_key` — model key from config.models map (default: `:large`)
    - `:skills` — list of skill names to pre-activate (default: `[]`)
    - Plus any `RLM.Config` overrides

  Returns `{:ok, session_id}`.
  """
  @spec start_session(keyword()) :: {:ok, String.t()} | {:error, any()}
  def start_session(opts \\ []) do
    config = RLM.Config.load(opts)
    session_id = RLM.Span.generate_id()
    run_id = RLM.Span.generate_run_id()
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model_key = Keyword.get(opts, :model_key, :large)

    {skill_catalog, activated_skills} = resolve_skills(opts)

    run_opts = [run_id: run_id, config: config, keep_alive: true]

    case DynamicSupervisor.start_child(RLM.RunSup, {RLM.Run, run_opts}) do
      {:ok, run_pid} ->
        worker_opts = [
          span_id: session_id,
          run_id: run_id,
          config: config,
          keep_alive: true,
          cwd: cwd,
          model_key: model_key,
          skill_catalog: skill_catalog,
          activated_skills: activated_skills
        ]

        case RLM.Run.start_worker(run_pid, worker_opts) do
          {:ok, _pid} ->
            {:ok, session_id}

          {:error, reason} ->
            terminate_run(run_pid)
            {:error, "Failed to start session: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to start run: #{inspect(reason)}"}
    end
  end

  @doc """
  Send a message to a keep-alive session and wait for the response.

  Returns `{:ok, answer}` or `{:error, reason}`.
  """
  @spec send_message(String.t(), String.t(), timeout()) ::
          {:ok, any()} | {:error, any()}
  def send_message(session_id, text, timeout \\ :infinity) do
    GenServer.call(via(session_id), {:send_message, text}, timeout)
  end

  @doc "Get the full message history for a session."
  @spec history(String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def history(session_id) do
    {:ok, GenServer.call(via(session_id), :history)}
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Get the status of a session."
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(session_id) do
    {:ok, GenServer.call(via(session_id), :status)}
  catch
    :exit, _ -> {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Replay API
  # ---------------------------------------------------------------------------

  @doc """
  Replay a previously recorded run.

  Requires the original run to have been executed with `enable_replay_recording: true`.
  The replay re-executes all eval'd code using the recorded LLM responses.

  ## Options

    * `:patch` — `%{iteration => code}` map to replace code at specific iterations
    * `:fallback` — `:error` (default) or `:live` to switch to live LLM calls
      when the tape runs out (e.g., because a patch caused extra iterations)
    * `:config` — config overrides for the replay run (set `llm_module` here
      to control which module handles live fallback calls)

  Returns `{:ok, answer, replay_run_id}` or `{:error, reason}`.
  """
  @spec replay(String.t(), keyword()) :: {:ok, any(), String.t()} | {:error, any()}
  def replay(run_id, opts \\ []) do
    RLM.Replay.replay(run_id, opts)
  end

  # ---------------------------------------------------------------------------
  # Run management
  # ---------------------------------------------------------------------------

  @doc false
  def terminate_run(run_pid) when is_pid(run_pid) do
    if Process.alive?(run_pid) do
      DynamicSupervisor.terminate_child(RLM.RunSup, run_pid)
    end
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Skill resolution
  # ---------------------------------------------------------------------------

  defp resolve_skills(opts) do
    skill_names = Keyword.get(opts, :skills, [])

    catalog =
      try do
        RLM.SkillRegistry.catalog()
      catch
        :exit, _ -> []
      end

    activated =
      Enum.reduce(skill_names, [], fn name, acc ->
        case RLM.SkillRegistry.get(name) do
          {:ok, skill} -> [skill | acc]
          :error -> acc
        end
      end)
      |> Enum.reverse()

    {catalog, activated}
  end

  defp via(session_id) do
    {:via, Registry, {RLM.Registry, {:worker, session_id}}}
  end
end
