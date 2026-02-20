defmodule RLM.Tools.EditFile do
  @moduledoc "Exact-string replacement in a file, guarded by uniqueness."

  @behaviour RLM.Tool

  @impl true
  def name, do: :edit_file

  @impl true
  def doc do
    """
    edit_file(path, old_string, new_string)

    Replace an exact string in a file with new content. The old_string must
    appear exactly once in the file (uniqueness guard). To prepend at the
    beginning, pass "" for old_string.

    ## Examples

        edit_file("lib/my_app.ex", "def old_name", "def new_name")
        edit_file("config/config.exs", "timeout: 5000", "timeout: 10_000")
    """
  end

  @spec execute(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, old_string, new_string) do
    case File.read(path) do
      {:ok, content} ->
        count = count_occurrences(content, old_string)

        cond do
          count == 0 and old_string == "" ->
            case File.write(path, new_string <> content) do
              :ok -> {:ok, "Inserted #{byte_size(new_string)} bytes at start of #{path}"}
              {:error, reason} -> {:error, "Write failed: #{:file.format_error(reason)}"}
            end

          count == 0 ->
            {:error, "String not found in #{path}"}

          count > 1 ->
            {:error, "String appears #{count} times in #{path} — must be unique"}

          true ->
            updated = String.replace(content, old_string, new_string, global: false)

            case File.write(path, updated) do
              :ok ->
                {:ok, "Replaced #{byte_size(old_string)} bytes with #{byte_size(new_string)} bytes in #{path}"}

              {:error, reason} ->
                {:error, "Write failed: #{:file.format_error(reason)}"}
            end
        end

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp count_occurrences(_string, pattern) when byte_size(pattern) == 0, do: 0

  defp count_occurrences(string, pattern) do
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
