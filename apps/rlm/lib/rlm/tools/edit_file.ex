defmodule RLM.Tools.EditFile do
  @moduledoc "Replace an exact string in a file with new content (uniqueness-guarded)."
  use RLM.Tool

  @impl true
  def name, do: "edit_file"

  @impl true
  def description do
    "Replace an exact string in a file with new content. " <>
      "The old_string must match exactly and be unique. " <>
      "Pass an empty old_string to prepend at the beginning."
  end

  @impl true
  def execute(%{"path" => path, "old_string" => old, "new_string" => new}) do
    case File.read(path) do
      {:ok, content} ->
        count = count_occurrences(content, old)

        cond do
          count == 0 and old == "" ->
            case File.write(path, new <> content) do
              :ok -> {:ok, "Inserted #{byte_size(new)} bytes at start of #{path}"}
              {:error, reason} -> {:error, "Write failed: #{:file.format_error(reason)}"}
            end

          count == 0 ->
            {:error, "String not found in #{path}"}

          count > 1 ->
            {:error, "String appears #{count} times in #{path} — must be unique"}

          true ->
            updated = String.replace(content, old, new, global: false)

            case File.write(path, updated) do
              :ok ->
                {:ok, "Replaced #{byte_size(old)} bytes with #{byte_size(new)} bytes in #{path}"}

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
