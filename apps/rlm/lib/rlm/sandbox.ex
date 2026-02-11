defmodule RLM.Sandbox do
  @moduledoc """
  Functions available inside eval'd code.
  Delegates helpers and provides LLM sub-call capabilities.
  """

  defdelegate chunks(string, size), to: RLM.Helpers
  defdelegate grep(pattern, string), to: RLM.Helpers
  defdelegate preview(term, n \\ 500), to: RLM.Helpers

  @doc "List current bindings with their names, types, and sizes."
  def list_bindings do
    Process.get(:rlm_bindings_info, [])
  end

  @doc """
  Invoke a sub-LLM on the given text. Blocks until the sub-call completes.
  Returns {:ok, response} or {:error, reason}.
  """
  def lm_query(text, opts \\ []) do
    worker_pid = Process.get(:rlm_worker_pid)

    if is_nil(worker_pid) do
      {:error, "lm_query not available (no worker context)"}
    else
      model_size = Keyword.get(opts, :model_size, :small)
      GenServer.call(worker_pid, {:spawn_subcall, text, model_size}, :infinity)
    end
  end

  @doc """
  Invoke multiple sub-LLMs concurrently. Returns results in order.
  Each item in `inputs` is {text, opts} or just text.
  """
  def parallel_query(inputs, default_opts \\ [model_size: :small]) do
    worker_pid = Process.get(:rlm_worker_pid)

    if is_nil(worker_pid) do
      Enum.map(inputs, fn _ -> {:error, "lm_query not available"} end)
    else
      inputs
      |> Enum.map(fn
        {text, opts} -> {text, opts}
        text when is_binary(text) -> {text, default_opts}
      end)
      |> Enum.map(fn {text, opts} ->
        Task.async(fn ->
          model_size = Keyword.get(opts, :model_size, :small)
          GenServer.call(worker_pid, {:spawn_subcall, text, model_size}, :infinity)
        end)
      end)
      |> Task.await_many(:infinity)
    end
  end
end
