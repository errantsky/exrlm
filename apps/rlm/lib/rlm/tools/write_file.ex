defmodule RLM.Tools.WriteFile do
  @moduledoc "Write or overwrite a file with the given content."
  use RLM.Tool

  @impl true
  def name, do: "write_file"

  @impl true
  def description, do: "Write or overwrite a file. Creates parent directories as needed."

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
