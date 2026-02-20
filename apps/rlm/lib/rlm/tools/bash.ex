defmodule RLM.Tools.Bash do
  @moduledoc "Run shell commands with timeout enforcement."

  @behaviour RLM.Tool

  require Logger

  @default_timeout_ms 30_000
  @max_timeout_ms 300_000
  @max_output_bytes 50_000

  @impl true
  def name, do: :bash

  @impl true
  def doc do
    """
    bash(command, opts \\\\ [])

    Run a bash command and return its combined stdout+stderr output.
    Output is truncated to 50KB if it exceeds that limit.

    ## Options

      - :timeout_ms — timeout in milliseconds (default: 30000, max: 300000)
      - :cwd — working directory (default: process cwd or File.cwd!())

    ## Examples

        bash("mix test")
        bash("ls -la", cwd: "/tmp")
        bash("mix compile --warnings-as-errors", timeout_ms: 60_000)
    """
  end

  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(command, opts \\ []) do
    timeout = min(Keyword.get(opts, :timeout_ms, @default_timeout_ms), @max_timeout_ms)
    cwd = Keyword.get(opts, :cwd, Process.get(:rlm_cwd, File.cwd!()))

    Logger.debug("Bash tool executing: #{command}")

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], stderr_to_stdout: true, cd: cwd)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        truncated =
          if byte_size(output) > @max_output_bytes do
            binary_slice(output, 0, @max_output_bytes) <>
              "\n[... truncated — #{byte_size(output)} bytes total ...]"
          else
            output
          end

        if exit_code == 0 do
          {:ok, truncated}
        else
          {:error, "Exit code #{exit_code}:\n#{truncated}"}
        end

      nil ->
        {:error, "Command timed out after #{timeout}ms"}
    end
  rescue
    e -> {:error, "Command failed: #{Exception.message(e)}"}
  end
end
