defmodule RLM.Run do
  @moduledoc """
  Per-run coordinator GenServer.

  Each RLM execution (via `RLM.run/3` or `RLM.start_session/1`) creates a Run
  process that owns all workers and eval tasks for that run. The Run tracks the
  worker tree in an ETS table, monitors all workers for crash propagation, and
  provides cascade shutdown when the run completes or times out.

  ## Supervision topology

      RLM.RunSup (DynamicSupervisor)
      └── RLM.Run (per-run GenServer, :temporary)
          ├── DynamicSupervisor (workers) — linked
          └── Task.Supervisor (eval tasks) — linked

  Workers are `:temporary` — they don't restart on crash. The Run process
  detects crashes via monitoring and notifies parent workers so blocked
  `lm_query` calls receive error replies.

  ## ETS table schema

  Each row: `{span_id, parent_span_id, pid, depth, status, monitor_ref}`

  - `status` is one of `:running`, `:done`, `:crashed`
  - The table is owned by the Run process and cleaned up on termination

  ## Deadlock prevention

  Run → Worker communication is always `send/2` (never `GenServer.call`).
  Workers call Run synchronously (`GenServer.call`), and Run never calls
  back synchronously. This prevents Worker → Run → Worker call cycles.
  """
  use GenServer, restart: :temporary

  require Logger

  defstruct [
    :run_id,
    :config,
    :worker_sup,
    :eval_sup,
    :table,
    :keep_alive,
    monitors: %{}
  ]

  # -- Public API --

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
  end

  @doc "Start a worker under this run's supervision."
  @spec start_worker(pid(), keyword()) :: {:ok, pid()} | {:error, any()}
  def start_worker(run_pid, worker_opts) do
    GenServer.call(run_pid, {:start_worker, worker_opts})
  end

  @doc "Look up the Run process for a given run_id."
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(run_id) do
    case Registry.lookup(RLM.Registry, {:run, run_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    config = Keyword.get(opts, :config, RLM.Config.load())
    keep_alive = Keyword.get(opts, :keep_alive, false)

    Process.flag(:trap_exit, true)

    {:ok, worker_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, eval_sup} = Task.Supervisor.start_link()
    table = :ets.new(:"run_#{run_id}", [:set, :protected, read_concurrency: true])

    state = %__MODULE__{
      run_id: run_id,
      config: config,
      worker_sup: worker_sup,
      eval_sup: eval_sup,
      table: table,
      keep_alive: keep_alive,
      monitors: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_worker, worker_opts}, _from, state) do
    worker_opts =
      worker_opts
      |> Keyword.put(:run_pid, self())
      |> Keyword.put(:eval_sup, state.eval_sup)

    case DynamicSupervisor.start_child(state.worker_sup, {RLM.Worker, worker_opts}) do
      {:ok, pid} ->
        span_id = Keyword.fetch!(worker_opts, :span_id)
        parent_span_id = Keyword.get(worker_opts, :parent_span_id)
        depth = Keyword.get(worker_opts, :depth, 0)
        ref = Process.monitor(pid)
        :ets.insert(state.table, {span_id, parent_span_id, pid, depth, :running, ref})
        monitors = Map.put(state.monitors, ref, span_id)

        {:reply, {:ok, pid}, %{state | monitors: monitors}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:worker_done, span_id}, state) do
    case :ets.lookup(state.table, span_id) do
      [{^span_id, _, _, _, _, _}] ->
        :ets.update_element(state.table, span_id, {5, :done})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {span_id, remaining_monitors} ->
        new_state = %{state | monitors: remaining_monitors}

        if reason == :normal do
          :ets.update_element(state.table, span_id, {5, :done})
          maybe_auto_shutdown(new_state)
        else
          Logger.warning("Worker #{span_id} in run #{state.run_id} crashed: #{inspect(reason)}")

          :ets.update_element(state.table, span_id, {5, :crashed})

          # Look up crashed worker's parent and propagate
          case :ets.lookup(state.table, span_id) do
            [{^span_id, parent_span_id, _, _, _, _}] when not is_nil(parent_span_id) ->
              terminate_descendants(new_state, span_id)
              notify_parent_of_crash(new_state, parent_span_id, span_id, reason)

            _ ->
              terminate_descendants(new_state, span_id)
          end

          maybe_auto_shutdown(new_state)
        end
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.worker_sup ->
        Logger.error("Run #{state.run_id}: worker supervisor crashed: #{inspect(reason)}")
        {:stop, reason, state}

      pid == state.eval_sup ->
        Logger.error("Run #{state.run_id}: eval supervisor crashed: #{inspect(reason)}")
        {:stop, reason, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:auto_shutdown, state) do
    # Re-check: a new worker may have registered during the grace period
    if map_size(state.monitors) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.table != nil do
      :ets.delete(state.table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # -- Private --

  defp maybe_auto_shutdown(state) do
    if not state.keep_alive and map_size(state.monitors) == 0 do
      Process.send_after(self(), :auto_shutdown, 100)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp terminate_descendants(state, parent_span_id) do
    children = :ets.match_object(state.table, {:_, parent_span_id, :_, :_, :_, :_})

    Enum.each(children, fn {child_span_id, _, child_pid, _, _status, _ref} ->
      terminate_descendants(state, child_span_id)

      if is_pid(child_pid) and Process.alive?(child_pid) do
        DynamicSupervisor.terminate_child(state.worker_sup, child_pid)
      end
    end)
  end

  defp notify_parent_of_crash(state, parent_span_id, child_span_id, reason) do
    case :ets.lookup(state.table, parent_span_id) do
      [{^parent_span_id, _, parent_pid, _, :running, _}] ->
        if is_pid(parent_pid) and Process.alive?(parent_pid) do
          send(parent_pid, {:child_crashed, child_span_id, reason})
        end

      _ ->
        :ok
    end
  end

  defp via(run_id) do
    {:via, Registry, {RLM.Registry, {:run, run_id}}}
  end
end
