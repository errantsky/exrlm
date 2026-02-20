defmodule RLM.Tools.ReadFile do
  @moduledoc "Read the contents of a file (up to 100 KB)."
  use RLM.Tool

  @max_bytes 100_000

  @impl true
  def name, do: "read_file"

  @impl true
  def description, do: "Read the contents of a file. Returns up to 100KB of content."

  @impl true
  def execute(%{"path" => path}) do
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
