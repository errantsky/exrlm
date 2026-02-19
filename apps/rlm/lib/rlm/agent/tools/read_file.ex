defmodule RLM.Agent.Tools.ReadFile do
  use RLM.Agent.Tool

  @max_bytes 100_000

  @impl true
  def spec do
    %{
      "name" => "read_file",
      "description" => "Read the contents of a file. Returns up to 100KB of content.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Absolute or relative path to the file"
          }
        },
        "required" => ["path"]
      }
    }
  end

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
