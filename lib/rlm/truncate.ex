defmodule RLM.Truncate do
  @moduledoc """
  Head+tail string truncation.
  Shows first `head` characters and last `tail` characters with an omission marker.
  """

  @spec truncate(String.t(), keyword()) :: String.t()
  def truncate(string, opts \\ []) do
    head = Keyword.get(opts, :head, 4000)
    tail = Keyword.get(opts, :tail, 4000)
    total_len = String.length(string)

    if total_len <= head + tail do
      string
    else
      omitted = total_len - head - tail
      head_part = String.slice(string, 0, head)
      tail_part = String.slice(string, total_len - tail, tail)

      "#{head_part}\n\n[... #{omitted} characters omitted ...]\n\n#{tail_part}"
    end
  end
end
