defmodule RLM.Replay.LLM do
  @moduledoc """
  An LLM module that replays responses from a recorded tape.
  Used by `RLM.Replay.replay/2` to re-execute a run deterministically.

  Responses are consumed in order. If the tape runs out, returns an error.

  ## Process dictionary

  This uses the process dictionary because the `RLM.LLM` behaviour's `chat/4`
  callback doesn't have a slot for replay state. Since Worker calls `chat/4`
  synchronously from its own process, the tape state lives in the Worker's
  process dict. This matches the existing pattern where `RLM.Eval` uses
  process dict for `worker_pid`, `cwd`, etc.
  """

  @behaviour RLM.LLM

  @impl true
  def chat(_messages, _model, _config, _opts \\ []) do
    case pop_entry() do
      nil ->
        {:error, "Replay tape exhausted — no more recorded responses"}

      entry ->
        {:ok, entry.response, entry.usage}
    end
  end

  @doc "Initialize the replay state for the current process."
  @spec load_tape(RLM.Replay.Tape.t()) :: :ok
  def load_tape(%RLM.Replay.Tape{entries: entries}) do
    Process.put(:rlm_replay_entries, entries)
    :ok
  end

  defp pop_entry do
    case Process.get(:rlm_replay_entries, []) do
      [] ->
        nil

      [entry | rest] ->
        Process.put(:rlm_replay_entries, rest)
        entry
    end
  end
end
