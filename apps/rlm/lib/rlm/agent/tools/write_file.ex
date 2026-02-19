defmodule RLM.Agent.Tools.WriteFile do
  use RLM.Agent.Tool

  @impl true
  def spec do
    %{
      "name" => "write_file",
      "description" => "Write or overwrite a file with the given content.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to write to (directories will be created as needed)"
          },
          "content" => %{
            "type" => "string",
            "description" => "The full content to write to the file"
          }
        },
        "required" => ["path", "content"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} ->
        {:error, "Cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
