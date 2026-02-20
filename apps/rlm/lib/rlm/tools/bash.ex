defmodule RLM.Tools.Bash do
  @moduledoc "Run a bash command and return its combined stdout+stderr output."
  use RLM.Tool

  require Logger

  @default_timeout_ms 30_000
  @max_timeout_ms 300_000
  @max_output_bytes 50_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Run a bash command. Output is truncated to 50KB. " <>
      "Default timeout: 30s, max: 300s."
  end

  @impl true
  def execute(%{"command" => command} = input) do
    timeout = min(Map.get(input, "timeout_ms", @default_timeout_ms), @max_timeout_ms)
    cwd = Map.get(input, "cwd", File.cwd!())

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
