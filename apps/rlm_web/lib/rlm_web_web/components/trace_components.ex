defmodule RlmWebWeb.TraceComponents do
  @moduledoc """
  HEEx components for rendering RLM span trees and iteration cards.
  """
  use Phoenix.Component

  attr :span, :map, required: true
  attr :spans, :map, required: true
  attr :expanded, :any, required: true
  attr :depth, :integer, default: 0

  def span_node(assigns) do
    ~H"""
    <div class={["border-l-2 pl-4 mb-2", depth_color(@depth)]}>
      <div class="flex items-center gap-2 mb-1 flex-wrap">
        <.status_dot status={@span[:status]} />
        <span class="font-mono text-xs text-base-content/60">
          span:{String.slice(@span.span_id || "", 0, 6)}
        </span>
        <span class="badge badge-xs badge-neutral">{@span[:model] || "?"}</span>
        <span class="text-xs">depth={@span[:depth] || 0}</span>
        <span :if={@span[:context_bytes]} class="text-xs text-base-content/50">
          {format_bytes(@span.context_bytes)}
        </span>
        <span :if={@span[:duration_ms]} class="text-xs ml-auto text-base-content/70">
          {format_duration(@span[:duration_ms])}
        </span>
        <span :if={@span[:total_iterations]} class="text-xs text-base-content/70">
          · {@span.total_iterations} iters
        </span>
      </div>

      <div :if={@span[:iterations] && @span.iterations != []} class="ml-2 mb-2 space-y-1">
        <.iteration_card
          :for={{iter, idx} <- Enum.with_index(@span.iterations)}
          iteration={iter}
          span_id={@span.span_id}
          index={idx}
          expanded={@expanded}
        />
      </div>

      <.span_node
        :for={child_id <- child_ids(@span.span_id, @spans)}
        span={@spans[child_id]}
        spans={@spans}
        expanded={@expanded}
        depth={@depth + 1}
      />
    </div>
    """
  end

  attr :iteration, :map, required: true
  attr :span_id, :string, required: true
  attr :index, :integer, required: true
  attr :expanded, :any, required: true

  def iteration_card(assigns) do
    key = {assigns.span_id, assigns.index}
    assigns = assign(assigns, :is_expanded, MapSet.member?(assigns.expanded, key))
    assigns = assign(assigns, :key, key)

    ~H"""
    <div class="border border-base-300 rounded text-xs">
      <div
        class="flex items-center gap-2 px-2 py-1 cursor-pointer hover:bg-base-200 select-none"
        phx-click="toggle_iteration"
        phx-value-span_id={@span_id}
        phx-value-index={@index}
      >
        <span class="font-mono text-base-content/50">iter #{@iteration[:iteration] || @index}</span>
        <span :if={@iteration[:duration_ms]} class="text-base-content/70">
          {format_duration(@iteration.duration_ms)}
        </span>
        <.eval_badge status={@iteration[:eval_status]} />
        <span :if={@iteration[:llm_prompt_tokens]} class="text-base-content/50 ml-auto">
          ↑{@iteration.llm_prompt_tokens} ↓{@iteration[:llm_completion_tokens]}
          <span
            :if={@iteration[:cache_read_input_tokens] && @iteration.cache_read_input_tokens > 0}
            class="text-success"
          >
            cached:{@iteration.cache_read_input_tokens}
          </span>
        </span>
        <span class="ml-auto text-base-content/40">
          {if @is_expanded, do: "▲", else: "▼"}
        </span>
      </div>

      <div :if={@is_expanded} class="border-t border-base-300 p-2 space-y-2">
        <div :if={@iteration[:code]}>
          <p class="text-base-content/50 mb-1 uppercase tracking-wide text-[10px]">Code</p>
          <pre class="bg-base-300 rounded p-2 overflow-x-auto text-xs"><code><%= @iteration.code %></code></pre>
        </div>

        <div :if={@iteration[:stdout_preview]}>
          <p class="text-base-content/50 mb-1 uppercase tracking-wide text-[10px]">
            Stdout
            <span :if={@iteration[:stdout_bytes]}>
              ({format_bytes(@iteration.stdout_bytes)})
            </span>
          </p>
          <pre class="bg-base-300 rounded p-2 overflow-x-auto text-xs max-h-48"><%= @iteration.stdout_preview %></pre>
        </div>

        <div :if={@iteration[:bindings_snapshot] && @iteration.bindings_snapshot != []}>
          <p class="text-base-content/50 mb-1 uppercase tracking-wide text-[10px]">Bindings</p>
          <table class="w-full text-xs">
            <tr
              :for={{name, type, bytes, preview} <- @iteration.bindings_snapshot}
              class="border-b border-base-200"
            >
              <td class="py-0.5 pr-2 font-mono font-semibold">{name}</td>
              <td class="py-0.5 font-mono text-base-content/70">{type}</td>
              <td class="py-0.5 font-mono text-base-content/50 text-right">{format_bytes(bytes)}</td>
              <td class="py-0.5 pl-2 font-mono text-base-content/60 truncate max-w-xs" title={preview}>
                {preview}
              </td>
            </tr>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp status_dot(assigns) do
    ~H"""
    <span class={[
      "inline-block w-2 h-2 rounded-full",
      @status == :ok && "bg-success",
      @status == :running && "bg-warning animate-pulse",
      @status == :error && "bg-error",
      is_nil(@status) && "bg-base-300"
    ]} />
    """
  end

  defp eval_badge(assigns) do
    ~H"""
    <span
      :if={@status}
      class={[
        "badge badge-xs",
        @status == :ok && "badge-success",
        @status == :error && "badge-error",
        @status not in [:ok, :error] && "badge-neutral"
      ]}
    >
      {@status}
    </span>
    """
  end

  defp child_ids(span_id, spans) do
    spans
    |> Map.values()
    |> Enum.filter(&(&1[:parent_span_id] == span_id))
    |> Enum.sort_by(& &1[:started_at])
    |> Enum.map(& &1.span_id)
  end

  defp depth_color(0), do: "border-primary"
  defp depth_color(1), do: "border-secondary"
  defp depth_color(2), do: "border-accent"
  defp depth_color(_), do: "border-base-300"

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_bytes(nil), do: ""
  defp format_bytes(b) when b < 1024, do: "#{b}B"
  defp format_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1024, 1)}KB"
  defp format_bytes(b), do: "#{Float.round(b / 1_048_576, 1)}MB"
end
