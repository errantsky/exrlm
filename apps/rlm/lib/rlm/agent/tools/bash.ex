defmodule RLM.Agent.Tools.Bash do
  use RLM.Agent.Tool

  @default_timeout_ms 30_000
  @max_output_bytes 50_000

  @impl true
  def spec do
    %{
      "name" => "bash",
      "description" => """
      Run a bash command and return its combined stdout+stderr output.
      Avoid interactive commands. Working directory is the project root.
      Output is truncated to 50KB if it exceeds that limit.
      """,
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to execute"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: 30000)"
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl true
  def execute(%{"command" => command} = input) do
    timeout = Map.get(input, "timeout_ms", @default_timeout_ms)

    task =
      Task.async(fn ->
        System.cmd("bash", ["-c", command], stderr_to_stdout: true)
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
