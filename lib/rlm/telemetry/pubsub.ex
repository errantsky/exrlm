defmodule RLM.Telemetry.PubSub do
  @moduledoc """
  Broadcasts telemetry events via Phoenix.PubSub for LiveView consumption.
  """

  def handle_event(event_name, measurements, metadata, _config) do
    msg = %{
      event: event_name,
      measurements: measurements,
      metadata: metadata,
      timestamp: System.monotonic_time(:microsecond)
    }

    Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:runs", msg)

    if run_id = metadata[:run_id] do
      Phoenix.PubSub.broadcast(RLM.PubSub, "rlm:run:#{run_id}", msg)
    end
  rescue
    _ -> :ok
  end
end
