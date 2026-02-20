defmodule RLM.TraceStore do
  @moduledoc """
  Persistent trace storage backed by :dets.

  Stores `{run_id, event}` tuples in a `:bag` table so that multiple events
  can be associated with a single run. Used as a fallback when the in-memory
  EventLog Agent has been swept.
  """
  use GenServer

  @table :rlm_traces

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Asynchronously insert an event for the given run."
  def put_event(run_id, event) do
    GenServer.cast(__MODULE__, {:put_event, run_id, event})
  end

  @doc "Return all events for a run in chronological order."
  def get_events(run_id) do
    GenServer.call(__MODULE__, {:get_events, run_id})
  end

  @doc "Return a list of distinct run IDs stored in the table."
  def list_run_ids do
    GenServer.call(__MODULE__, :list_run_ids)
  end

  @doc "Delete all events whose `timestamp_us` is less than `cutoff_us`."
  def delete_older_than(cutoff_us) do
    GenServer.call(__MODULE__, {:delete_older_than, cutoff_us})
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    path = Application.app_dir(:rlm, "priv/traces.dets") |> String.to_charlist()
    {:ok, @table} = :dets.open_file(@table, file: path, type: :bag)
    {:ok, %{table: @table}}
  end

  @impl true
  def handle_cast({:put_event, run_id, event}, state) do
    :dets.insert(@table, {run_id, event})
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_events, run_id}, _from, state) do
    events =
      :dets.lookup(@table, run_id)
      |> Enum.map(fn {_run_id, event} -> event end)
      |> Enum.sort_by(& &1[:timestamp_us])

    {:reply, events, state}
  end

  def handle_call(:list_run_ids, _from, state) do
    run_ids =
      :dets.foldl(
        fn {run_id, _event}, acc -> MapSet.put(acc, run_id) end,
        MapSet.new(),
        @table
      )
      |> MapSet.to_list()

    {:reply, run_ids, state}
  end

  def handle_call({:delete_older_than, cutoff_us}, _from, state) do
    # Match spec: match {_run_id, event} where event is a map with timestamp_us < cutoff_us
    # Since :dets.select_delete works on the raw tuple, we use :dets.foldl to find and delete.
    :dets.foldl(
      fn {run_id, event} = _record, acc ->
        if is_map(event) and Map.get(event, :timestamp_us, 0) < cutoff_us do
          :dets.delete_object(@table, {run_id, event})
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
  end
end
