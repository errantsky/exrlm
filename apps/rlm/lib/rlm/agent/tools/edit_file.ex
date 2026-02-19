defmodule RLM.Agent.Tools.EditFile do
  use RLM.Agent.Tool

  @impl true
  def spec do
    %{
      "name" => "edit_file",
      "description" => """
      Replace an exact string in a file with new content.
      The `old_string` must match exactly (including whitespace and newlines).
      To insert text, use an empty string for old_string and provide the content.
      """,
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file to edit"},
          "old_string" => %{
            "type" => "string",
            "description" => "Exact text to find (must be unique in the file)"
          },
          "new_string" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["path", "old_string", "new_string"]
      }
    }
  end

  @impl true
  def execute(%{"path" => path, "old_string" => old, "new_string" => new}) do
    case File.read(path) do
      {:ok, content} ->
        count = count_occurrences(content, old)

        cond do
          count == 0 and old == "" ->
            # Insert at beginning
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

  defp count_occurrences(string, pattern) when byte_size(pattern) == 0, do: 0

  defp count_occurrences(string, pattern) do
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
