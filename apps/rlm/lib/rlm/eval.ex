defmodule RLM.Eval do
  @moduledoc """
  Sandboxed code evaluation with IO capture and timeout.
  Runs eval'd code in a spawned process with the Worker PID available
  for sandbox functions to communicate back.

  NOTE: This module intentionally uses Code.eval_string/3 as the core
  mechanism for the RLM REPL. The LLM writes Elixir code that gets
  evaluated in a persistent binding context. This is the fundamental
  design of the Recursive Language Model architecture.
  """

  @spec run(String.t(), keyword(), keyword()) ::
          {:ok, String.t(), any(), keyword()} | {:error, String.t(), keyword()}
  def run(code, bindings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    worker_pid = Keyword.get(opts, :worker_pid)
    bindings_info = Keyword.get(opts, :bindings_info, [])

    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        # Capture stdout
        {:ok, string_io} = StringIO.open("")
        Process.group_leader(self(), string_io)

        # Inject runtime state for sandbox functions
        Process.put(:rlm_worker_pid, worker_pid)
        Process.put(:rlm_bindings_info, bindings_info)
        Process.put(:rlm_cwd, Keyword.get(opts, :cwd, File.cwd!()))

        wrapped_code = "import RLM.Sandbox\n#{code}"

        result =
          try do
            # Code.eval_string is the intentional REPL mechanism for RLM
            {value, new_bindings} =
              Code.eval_string(wrapped_code, bindings, file: "rlm_repl", line: 0)

            stdout = StringIO.flush(string_io)
            {:ok, stdout, value, new_bindings}
          rescue
            e ->
              stdout = StringIO.flush(string_io)
              {:error, stdout, Exception.format(:error, e, __STACKTRACE__)}
          catch
            kind, reason ->
              stdout = StringIO.flush(string_io)
              {:error, stdout, Exception.format(kind, reason, __STACKTRACE__)}
          end

        send(caller, {:eval_result, self(), result})
      end)

    receive do
      {:eval_result, ^pid, {:ok, stdout, _value, new_bindings}} ->
        Process.demonitor(ref, [:flush])
        {:ok, stdout, nil, new_bindings}

      {:eval_result, ^pid, {:error, stdout, error_msg}} ->
        Process.demonitor(ref, [:flush])
        {:error, "#{error_msg}\n\nStdout before error:\n#{stdout}", bindings}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "Eval process crashed: #{inspect(reason)}", bindings}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])

        receive do
          {:eval_result, ^pid, _} -> :ok
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          100 -> :ok
        end

        {:error, "Code evaluation timed out after #{timeout}ms", bindings}
    end
  end
end
