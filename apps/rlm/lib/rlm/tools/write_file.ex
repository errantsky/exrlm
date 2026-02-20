defmodule RLM.Tools.WriteFile do
  @moduledoc "Write or overwrite a file, creating parent directories as needed."

  @behaviour RLM.Tool

  @impl true
  def name, do: :write_file

  @impl true
  def doc do
    """
    write_file(path, content)

    Write content to a file. Creates parent directories if they don't exist.
    Overwrites the file if it already exists.

    ## Examples

        write_file("output/results.txt", "hello world")
        write_file("lib/my_app/new_module.ex", ~s(defmodule MyApp.New do\\nend))
    """
  end

  @spec execute(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, content) do
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
