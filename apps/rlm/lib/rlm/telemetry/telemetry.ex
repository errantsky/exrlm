defmodule RLM.Telemetry do
  @moduledoc """
  Telemetry event definitions and handler attachment.
  Starts as a GenServer that attaches all handlers on init.
  """
  use GenServer

  @events [
    [:rlm, :node, :start],
    [:rlm, :node, :stop],
    [:rlm, :node, :exception],
    [:rlm, :iteration, :start],
    [:rlm, :iteration, :stop],
    [:rlm, :llm, :request, :start],
    [:rlm, :llm, :request, :stop],
    [:rlm, :llm, :request, :exception],
    [:rlm, :eval, :start],
    [:rlm, :eval, :stop],
    [:rlm, :eval, :exception],
    [:rlm, :subcall, :spawn],
    [:rlm, :subcall, :result],
    [:rlm, :compaction, :run],
    [:rlm, :turn, :complete]
  ]

  def events, do: @events

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    attach_all_handlers()
    {:ok, %{}}
  end

  def attach_all_handlers do
    :telemetry.attach_many(
      "rlm-logger",
      @events,
      &RLM.Telemetry.Logger.handle_event/4,
      nil
    )

    :telemetry.attach_many(
      "rlm-event-log",
      @events,
      &RLM.Telemetry.EventLogHandler.handle_event/4,
      nil
    )

    :telemetry.attach_many(
      "rlm-pubsub",
      @events,
      &RLM.Telemetry.PubSub.handle_event/4,
      nil
    )
  end

  def detach_all_handlers do
    :telemetry.detach("rlm-logger")
    :telemetry.detach("rlm-event-log")
    :telemetry.detach("rlm-pubsub")
  rescue
    _ -> :ok
  end
end
