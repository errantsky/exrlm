# Load API key from .env
env_path = Path.join(__DIR__, ".env")

if File.exists?(env_path) do
  env_path
  |> File.stream!()
  |> Enum.each(fn line ->
    line = String.trim(line)

    if line != "" and not String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
          System.put_env(String.trim(key), value)

        _ ->
          :ok
      end
    end
  end)
end

# Load a cross-section of the cookbook HTML (files 3-45: ~200 KB, rich recipe content)
path = Application.app_dir(:rlm, "priv/foodlab.epub")
{:ok, zip_files} = :zip.unzip(String.to_charlist(path), [:memory])

html =
  zip_files
  |> Enum.map(fn {name, content} -> {to_string(name), content} end)
  |> Enum.filter(fn {k, _} -> String.ends_with?(k, ".html") or String.ends_with?(k, ".xhtml") end)
  |> Enum.sort_by(fn {k, _} -> k end)
  |> Enum.slice(3, 42)
  |> Enum.map_join("\n\n", fn {name, content} -> "=== #{name} ===\n#{content}" end)

IO.puts("Input size: #{div(byte_size(html), 1024)} KB")

query = """
This is HTML from a cookbook. Identify the top 5 most frequently mentioned
main proteins (meats, fish, legumes) across all recipes in the content.

The input is large — split it into 3 roughly equal chunks and use
parallel_query to extract protein mentions from each chunk concurrently,
then aggregate and rank across all results.
"""

IO.puts("Starting RLM run...\n")

{:ok, answer, run_id} = RLM.run(html, query)

IO.puts("\n=== Answer ===")
IO.puts(answer)
IO.puts("\nRun ID: #{run_id}")
