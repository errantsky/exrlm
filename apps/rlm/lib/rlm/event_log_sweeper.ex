defmodule RLM.EventLog.Sweeper do
  @moduledoc """
  Periodically terminates stale EventLog agents from the RLM.EventStore
  DynamicSupervisor to prevent unbounded memory growth in long-running systems.

  Configured via opts:
    - `:interval` — sweep interval in ms (default: 5 minutes)
    - `:ttl`      — max age of an EventLog agent in ms (default: 1 hour)
  """
  use GenServer

  require Logger

  @default_interval :timer.minutes(5)
  @default_ttl :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    schedule_sweep(interval)
    {:ok, %{interval: interval, ttl: ttl}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.ttl)
    schedule_sweep(state.interval)
    {:noreply, state}
  end

  # -- Private --

  # EventLog stores started_at in microseconds; ttl arrives in milliseconds.
  defp sweep(ttl_ms) do
    cutoff_us = System.monotonic_time(:microsecond) - ttl_ms * 1_000

    DynamicSupervisor.which_children(RLM.EventStore)
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      if is_pid(pid) and Process.alive?(pid) do
        started_at = safe_get_started_at(pid)

        if is_integer(started_at) and started_at < cutoff_us do
          Logger.debug("EventLog.Sweeper: terminating stale agent #{inspect(pid)}")
          DynamicSupervisor.terminate_child(RLM.EventStore, pid)
        end
      end
    end)

    RLM.TraceStore.delete_older_than(cutoff_us)
  end

  # Use a short timeout so a busy/unresponsive Agent doesn't block the sweep.
  # Returns nil if the agent doesn't respond, has crashed, or has an unexpected
  # state shape — all of which are handled gracefully by the caller.
  defp safe_get_started_at(pid) do
    Agent.get(pid, & &1.started_at, 5_000)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
