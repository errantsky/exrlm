defmodule RLM.Tools.ReadFile do
  @moduledoc "Read file contents, capped at 100KB."

  @behaviour RLM.Tool

  @max_bytes 100_000

  @impl true
  def name, do: :read_file

  @impl true
  def doc do
    """
    read_file(path)

    Read the contents of a file and return it as a string.
    Files larger than 100KB are truncated with a notice.

    ## Examples

        content = read_file("lib/my_app/worker.ex")
        lines = read_file("mix.exs") |> String.split("\\n")
    """
  end

  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) do
    case File.read(path) do
      {:ok, content} ->
        truncated = binary_slice(content, 0, @max_bytes)

        output =
          if byte_size(content) > @max_bytes do
            truncated <> "\n[... truncated — #{byte_size(content)} bytes total ...]"
          else
            truncated
          end

        {:ok, output}

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end
end
