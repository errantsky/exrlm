defmodule RLM.Replay.FallbackLLM do
  @moduledoc """
  An LLM module that replays from a tape, falling back to a live LLM
  module when the tape is exhausted.

  Used by `RLM.Replay.replay/2` with `fallback: :live`. The fallback
  module is stored in the process dictionary alongside the tape entries.
  """

  @behaviour RLM.LLM

  require Logger

  @impl true
  def chat(messages, model, config, opts \\ []) do
    case pop_entry() do
      nil ->
        fallback_module = Process.get(:rlm_replay_fallback_module, RLM.LLM.ReqLLM)

        Logger.info(
          "Replay tape exhausted, falling back to live LLM (#{inspect(fallback_module)})"
        )

        fallback_module.chat(messages, model, config, opts)

      entry ->
        {:ok, entry.response, entry.usage}
    end
  end

  @doc "Initialize the replay state with tape entries and a fallback module."
  @spec load_tape(RLM.Replay.Tape.t(), module()) :: :ok
  def load_tape(%RLM.Replay.Tape{entries: entries}, fallback_module) do
    Process.put(:rlm_replay_entries, entries)
    Process.put(:rlm_replay_fallback_module, fallback_module)
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
