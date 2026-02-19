defmodule RLM.Agent.Tools.Ls do
  use RLM.Agent.Tool

  @impl true
  def spec do
    %{
      "name" => "ls",
      "description" => "List directory contents with file sizes and types.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Directory to list (default: current directory)"
          }
        },
        "required" => []
      }
    }
  end

  @impl true
  def execute(input) do
    path = Map.get(input, "path", ".")

    case File.ls(path) do
      {:ok, entries} ->
        formatted =
          entries
          |> Enum.sort()
          |> Enum.map(fn name ->
            full = Path.join(path, name)

            case File.stat(full) do
              {:ok, stat} ->
                type = if stat.type == :directory, do: "/", else: ""
                size = if stat.type == :regular, do: " (#{stat.size} bytes)", else: ""
                "#{name}#{type}#{size}"

              {:error, _} ->
                name
            end
          end)

        {:ok, Enum.join(formatted, "\n")}

      {:error, reason} ->
        {:error, "Cannot list #{path}: #{:file.format_error(reason)}"}
    end
  end
end
