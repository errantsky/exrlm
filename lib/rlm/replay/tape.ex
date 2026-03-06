defmodule RLM.Replay.Tape do
  @moduledoc """
  A replay tape: an ordered sequence of LLM responses from a recorded run.
  Built from EventLog events, consumed by the replay LLM module.
  """

  defstruct [:run_id, :context, :query, entries: []]

  @type entry :: %{
          iteration: non_neg_integer(),
          span_id: String.t(),
          response: String.t(),
          usage: map()
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          context: String.t() | nil,
          query: String.t() | nil,
          entries: [entry()]
        }

  @doc "Build a tape from EventLog events for a given run."
  @spec from_events(String.t()) :: {:ok, t()} | {:error, :no_events | :no_responses}
  def from_events(run_id) do
    events = get_events(run_id)

    if events == [] do
      {:error, :no_events}
    else
      node_start = Enum.find(events, &(&1.type == :node_start && &1[:depth] == 0))

      responses =
        events
        |> Enum.filter(&(&1.type == :llm_response))
        |> Enum.sort_by(& &1.iteration)
        |> Enum.map(fn e ->
          %{iteration: e.iteration, span_id: e.span_id, response: e.response, usage: e.usage}
        end)

      if responses == [] do
        {:error, :no_responses}
      else
        {:ok,
         %__MODULE__{
           run_id: run_id,
           context: node_start[:original_context],
           query: node_start[:original_query],
           entries: responses
         }}
      end
    end
  end

  # EventLog.get_events/1 raises an exit when no Agent exists for the run_id
  # (e.g., swept by the GC). Catch that and fall back to TraceStore.
  defp get_events(run_id) do
    case RLM.EventLog.get_events(run_id) do
      [] -> RLM.EventLog.get_events_from_store(run_id)
      events -> events
    end
  catch
    :exit, {:noproc, _} ->
      # Agent was swept — expected, fall back to persisted store
      RLM.EventLog.get_events_from_store(run_id)

    :exit, reason ->
      require Logger

      Logger.warning(
        "EventLog.get_events failed for run #{run_id}: #{inspect(reason)}, " <>
          "falling back to TraceStore"
      )

      RLM.EventLog.get_events_from_store(run_id)
  end
end
