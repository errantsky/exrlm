defmodule RLM.Helpers do
  @moduledoc """
  Utility functions available inside the REPL sandbox.
  """

  @spec chunks(String.t(), pos_integer()) :: Enumerable.t()
  def chunks(string, size) when is_binary(string) and is_integer(size) and size > 0 do
    Stream.unfold(string, fn
      "" ->
        nil

      remaining ->
        {String.slice(remaining, 0, size), String.slice(remaining, size..-1//1)}
    end)
  end

  @spec grep(String.t() | Regex.t(), String.t()) :: [{pos_integer(), String.t()}]
  def grep(pattern, string) when is_binary(string) do
    regex =
      case pattern do
        %Regex{} -> pattern
        pat when is_binary(pat) -> Regex.compile!(Regex.escape(pat))
      end

    string
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, idx} -> {idx, line} end)
  end

  @spec preview(term(), non_neg_integer()) :: String.t()
  def preview(term, n \\ 500) do
    inspected = inspect(term, limit: :infinity, printable_limit: :infinity)

    if String.length(inspected) <= n do
      inspected
    else
      String.slice(inspected, 0, n) <> "..."
    end
  end

  @spec list_bindings(keyword()) :: [{atom(), String.t(), non_neg_integer()}]
  def list_bindings(bindings) when is_list(bindings) do
    Enum.map(bindings, fn {name, value} ->
      type = type_of(value)
      size = byte_size_of(value)
      {name, type, size}
    end)
  end

  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_integer(value), do: "integer"
  defp type_of(value) when is_float(value), do: "float"
  defp type_of(value) when is_list(value), do: "list"
  defp type_of(value) when is_map(value), do: "map"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(value) when is_tuple(value), do: "tuple"
  defp type_of(value) when is_function(value), do: "function"
  defp type_of(_value), do: "other"

  defp byte_size_of(value) when is_binary(value), do: byte_size(value)

  defp byte_size_of(value) do
    value |> :erlang.term_to_binary() |> byte_size()
  end
end
