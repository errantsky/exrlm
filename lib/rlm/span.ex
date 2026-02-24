defmodule RLM.Span do
  @moduledoc """
  Span ID generation and context propagation helpers.
  """

  @spec generate_id() :: String.t()
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  @spec generate_run_id() :: String.t()
  def generate_run_id do
    "run_" <> generate_id()
  end
end
