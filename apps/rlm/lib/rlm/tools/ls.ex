defmodule RLM.Tools.Ls do
  @moduledoc "List directory contents with file sizes and types."

  @behaviour RLM.Tool

  @impl true
  def name, do: :ls

  @impl true
  def doc do
    """
    ls(path \\\\ ".")

    List directory contents with sizes and types. Directories are
    shown with a trailing /, regular files show their byte size.

    ## Examples

        ls()
        ls("lib/my_app")
        ls("/tmp")
    """
  end

  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path \\ ".") do
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
