defmodule RLM.Worker do
  @moduledoc """
  GenServer that owns one RLM node's state.
  Each Worker runs the iterate loop: call LLM -> run code -> check final_answer -> repeat.
  Sub-calls spawn child Workers via DynamicSupervisor.

  Eval runs asynchronously so the Worker can process subcall requests
  from the eval process without deadlocking.

  ## Modes

  - **One-shot** (default): starts iterating immediately, terminates after `final_answer`.
  - **Keep-alive** (`keep_alive: true`): starts idle, accepts `send_message` calls,
    stays alive between turns. Bindings persist across turns.

  ## Structured Output

  LLM responses are JSON objects with `reasoning` and `code` fields,
  constrained via Claude's `output_config` JSON schema. Feedback messages
  after eval are also structured JSON.
  """
  use GenServer, restart: :temporary

  require Logger

  defstruct [
    :span_id,
    :parent_span_id,
    :run_id,
    :depth,
    :iteration,
    :history,
    :bindings,
    :model,
    :config,
    :status,
    :result,
    :prev_codes,
    :caller,
    :started_at,
    # Tracks in-flight eval context
    :eval_context,
    # keep_alive mode fields
    :keep_alive,
    :cwd,
    :pending_from,
    pending_subcalls: %{}
  ]

  # -- Public API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: via(Keyword.get(opts, :span_id, RLM.Span.generate_id()))
    )
  end

  defp via(span_id) do
    {:via, Registry, {RLM.Registry, {:worker, span_id}}}
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    span_id = Keyword.get(opts, :span_id, RLM.Span.generate_id())
    run_id = Keyword.get(opts, :run_id, RLM.Span.generate_run_id())
    config = Keyword.get(opts, :config, RLM.Config.load())
    context = Keyword.get(opts, :context, "")
    query = Keyword.get(opts, :query, context)
    depth = Keyword.get(opts, :depth, 0)
    model = Keyword.get(opts, :model, config.model_large)
    parent_span_id = Keyword.get(opts, :parent_span_id)
    caller = Keyword.get(opts, :caller)
    keep_alive = Keyword.get(opts, :keep_alive, false)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if keep_alive do
      # Keep-alive mode: start idle, wait for send_message
      system_msg = RLM.Prompt.build_system_message()

      state = %__MODULE__{
        span_id: span_id,
        parent_span_id: parent_span_id,
        run_id: run_id,
        depth: depth,
        iteration: 0,
        history: [system_msg],
        bindings: [final_answer: nil, compacted_history: ""],
        model: model,
        config: config,
        status: :idle,
        result: nil,
        prev_codes: [],
        caller: nil,
        started_at: System.monotonic_time(:millisecond),
        eval_context: nil,
        keep_alive: true,
        cwd: cwd,
        pending_from: nil
      }

      emit_telemetry([:rlm, :node, :start], %{}, state, %{
        context_bytes: 0,
        query_preview: "(keep_alive session)"
      })

      {:ok, state}
    else
      # One-shot mode: existing behavior
      context_bytes = byte_size(context)
      context_lines = length(String.split(context, "\n"))
      context_preview = String.slice(context, 0, 500)

      bindings = [
        context: context,
        final_answer: nil,
        compacted_history: ""
      ]

      system_msg = RLM.Prompt.build_system_message()

      user_msg =
        RLM.Prompt.build_user_message(query, context_bytes, context_lines, context_preview)

      state = %__MODULE__{
        span_id: span_id,
        parent_span_id: parent_span_id,
        run_id: run_id,
        depth: depth,
        iteration: 0,
        history: [system_msg, user_msg],
        bindings: bindings,
        model: model,
        config: config,
        status: :running,
        result: nil,
        prev_codes: [],
        caller: caller,
        started_at: System.monotonic_time(:millisecond),
        eval_context: nil,
        keep_alive: false,
        cwd: cwd,
        pending_from: nil
      }

      emit_telemetry([:rlm, :node, :start], %{}, state, %{
        context_bytes: context_bytes,
        query_preview: String.slice(query, 0, 200)
      })

      send(self(), :iterate)
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:iterate, state) do
    if state.iteration >= state.config.max_iterations do
      complete(state, {:error, "Maximum iterations (#{state.config.max_iterations}) reached"})
    else
      state = maybe_compact(state)

      emit_telemetry([:rlm, :iteration, :start], %{}, state, %{
        iteration: state.iteration
      })

      iter_start = System.monotonic_time(:millisecond)

      # Step 1: Call LLM (synchronous — LLM calls don't need GenServer reentrancy)
      llm_module = state.config.llm_module
      llm_start = System.monotonic_time(:millisecond)

      emit_telemetry([:rlm, :llm, :request, :start], %{}, state, %{
        messages_count: length(state.history)
      })

      case llm_module.chat(state.history, state.model, state.config) do
        {:ok, response, usage} ->
          llm_duration = System.monotonic_time(:millisecond) - llm_start

          # Step 2: Parse structured JSON response
          case RLM.LLM.extract_structured(response) do
            {:ok, %{reasoning: reasoning, code: code}} ->
              emit_telemetry(
                [:rlm, :llm, :request, :stop],
                %{
                  duration_ms: llm_duration,
                  prompt_tokens: usage.prompt_tokens || 0,
                  completion_tokens: usage.completion_tokens || 0,
                  total_tokens: usage.total_tokens || 0
                },
                state,
                %{
                  response_preview: String.slice(response, 0, 500),
                  code_present: code != "",
                  reasoning_preview: String.slice(reasoning, 0, 500)
                }
              )

              if code != "" do
                start_async_eval(
                  state,
                  response,
                  code,
                  reasoning,
                  llm_duration,
                  usage,
                  iter_start
                )
              else
                # Empty code — model chose not to execute this turn
                assistant_msg = %{role: :assistant, content: response}
                feedback = RLM.Prompt.build_empty_code_feedback()

                state = %{
                  state
                  | history: state.history ++ [assistant_msg, feedback],
                    iteration: state.iteration + 1
                }

                iter_duration = System.monotonic_time(:millisecond) - iter_start
                emit_iteration_stop(state, iter_duration, nil, "", usage, llm_duration)

                send(self(), :iterate)
                {:noreply, state}
              end

            {:error, parse_error} ->
              # Structured output parse failure — defensive path
              emit_telemetry(
                [:rlm, :llm, :request, :stop],
                %{
                  duration_ms: llm_duration,
                  prompt_tokens: usage.prompt_tokens || 0,
                  completion_tokens: usage.completion_tokens || 0,
                  total_tokens: usage.total_tokens || 0
                },
                state,
                %{
                  response_preview: String.slice(response, 0, 500),
                  code_present: false,
                  parse_error: parse_error
                }
              )

              complete(state, {:error, "Structured output parse failed: #{parse_error}"})
          end

        {:error, reason} ->
          llm_duration = System.monotonic_time(:millisecond) - llm_start

          emit_telemetry(
            [:rlm, :llm, :request, :exception],
            %{
              duration_ms: llm_duration
            },
            state,
            %{error: reason}
          )

          complete(state, {:error, "LLM call failed: #{reason}"})
      end
    end
  end

  # Async eval result — NOTE: Code.eval_string is the intentional REPL mechanism
  # for the RLM architecture. See RLM.Eval for full documentation.
  def handle_info({:eval_complete, eval_result}, state) do
    ctx = state.eval_context
    code_duration = System.monotonic_time(:millisecond) - ctx.code_start

    case eval_result do
      {:ok, stdout, _value, new_bindings} ->
        emit_telemetry([:rlm, :eval, :stop], %{duration_ms: code_duration}, state, %{
          status: :ok,
          stdout_bytes: byte_size(stdout)
        })

        truncated =
          RLM.Truncate.truncate(stdout,
            head: state.config.truncation_head,
            tail: state.config.truncation_tail
          )

        final_answer = Keyword.get(new_bindings, :final_answer)
        bindings_info = RLM.Helpers.list_bindings(new_bindings)

        feedback =
          RLM.Prompt.build_feedback_message(
            truncated,
            :ok,
            bindings_info,
            final_answer != nil
          )

        state = %{
          state
          | history: state.history ++ [ctx.assistant_msg, feedback],
            bindings: new_bindings,
            iteration: state.iteration + 1,
            prev_codes: Enum.take([ctx.code | state.prev_codes], 3),
            eval_context: nil
        }

        state = maybe_nudge(state)

        iter_duration = System.monotonic_time(:millisecond) - ctx.iter_start

        emit_telemetry([:rlm, :iteration, :stop], %{duration_ms: iter_duration}, state, %{
          iteration: state.iteration - 1,
          code: ctx.code,
          reasoning_preview: String.slice(ctx.reasoning, 0, 500),
          stdout_preview: String.slice(stdout, 0, 500),
          stdout_bytes: byte_size(stdout),
          eval_status: :ok,
          eval_duration_ms: code_duration,
          result_preview: inspect(final_answer) |> String.slice(0, 500),
          final_answer: final_answer,
          bindings_snapshot: bindings_info,
          subcalls_spawned: 0,
          llm_prompt_tokens: ctx.usage.prompt_tokens,
          llm_completion_tokens: ctx.usage.completion_tokens,
          llm_duration_ms: ctx.llm_duration
        })

        if final_answer != nil do
          complete(state, {:ok, final_answer})
        else
          send(self(), :iterate)
          {:noreply, state}
        end

      {:error, error_msg, original_bindings} ->
        emit_telemetry([:rlm, :eval, :stop], %{duration_ms: code_duration}, state, %{
          status: :error,
          stdout_bytes: byte_size(error_msg)
        })

        truncated =
          RLM.Truncate.truncate(error_msg,
            head: state.config.truncation_head,
            tail: state.config.truncation_tail
          )

        bindings_info = RLM.Helpers.list_bindings(original_bindings)

        feedback =
          RLM.Prompt.build_feedback_message(truncated, :error, bindings_info, false)

        state = %{
          state
          | history: state.history ++ [ctx.assistant_msg, feedback],
            bindings: original_bindings,
            iteration: state.iteration + 1,
            prev_codes: Enum.take([ctx.code | state.prev_codes], 3),
            eval_context: nil
        }

        iter_duration = System.monotonic_time(:millisecond) - ctx.iter_start

        emit_telemetry([:rlm, :iteration, :stop], %{duration_ms: iter_duration}, state, %{
          iteration: state.iteration - 1,
          code: ctx.code,
          reasoning_preview: String.slice(ctx.reasoning, 0, 500),
          stdout_preview: String.slice(error_msg, 0, 500),
          stdout_bytes: byte_size(error_msg),
          eval_status: :error,
          eval_duration_ms: code_duration,
          result_preview: "",
          final_answer: nil,
          bindings_snapshot: bindings_info,
          subcalls_spawned: 0,
          llm_prompt_tokens: ctx.usage.prompt_tokens,
          llm_completion_tokens: ctx.usage.completion_tokens,
          llm_duration_ms: ctx.llm_duration
        })

        send(self(), :iterate)
        {:noreply, state}
    end
  end

  def handle_info({:direct_query_result, query_id, result}, state) do
    case Map.pop(state.pending_subcalls, query_id) do
      {nil, _} ->
        Logger.warning("Received result for unknown direct query #{query_id}")
        {:noreply, state}

      {from, remaining} ->
        emit_telemetry(
          [:rlm, :direct_query, :stop],
          %{},
          state,
          %{
            query_id: query_id,
            status: elem(result, 0),
            result_preview: result |> inspect() |> String.slice(0, 500)
          }
        )

        GenServer.reply(from, result)
        {:noreply, %{state | pending_subcalls: remaining}}
    end
  end

  def handle_info({:rlm_result, child_span_id, result}, state) do
    case Map.pop(state.pending_subcalls, child_span_id) do
      {nil, _} ->
        Logger.warning("Received result for unknown subcall #{child_span_id}")
        {:noreply, state}

      {from, remaining} ->
        emit_telemetry(
          [:rlm, :subcall, :result],
          %{
            duration_ms: 0
          },
          state,
          %{
            child_span_id: child_span_id,
            status: elem(result, 0),
            result_preview: result |> inspect() |> String.slice(0, 500)
          }
        )

        GenServer.reply(from, result)
        {:noreply, %{state | pending_subcalls: remaining}}
    end
  end

  @impl true
  def handle_call({:send_message, text}, from, state) do
    case state.status do
      :running ->
        {:reply, {:error, "Worker is busy"}, state}

      :idle ->
        user_msg = %{role: :user, content: text}

        state = %{
          state
          | history: state.history ++ [user_msg],
            status: :running,
            pending_from: from,
            iteration: 0,
            prev_codes: [],
            bindings: Keyword.put(state.bindings, :final_answer, nil)
        }

        send(self(), :iterate)
        {:noreply, state}
    end
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       session_id: state.span_id,
       run_id: state.run_id,
       status: state.status,
       iteration: state.iteration,
       message_count: length(state.history),
       keep_alive: state.keep_alive,
       cwd: state.cwd
     }, state}
  end

  def handle_call({:direct_query, text, model_size, schema}, from, state) do
    model =
      if model_size == :large,
        do: state.config.model_large,
        else: state.config.model_small

    if map_size(state.pending_subcalls) >= state.config.max_concurrent_subcalls do
      {:reply,
       {:error, "Max concurrent subcalls (#{state.config.max_concurrent_subcalls}) reached"},
       state}
    else
      query_id = RLM.Span.generate_id()

      emit_telemetry([:rlm, :direct_query, :start], %{}, state, %{
        query_id: query_id,
        model_size: model_size,
        text_bytes: byte_size(text)
      })

      llm_module = state.config.llm_module
      config = state.config
      worker_pid = self()

      spawn(fn ->
        result =
          case llm_module.chat([%{role: :user, content: text}], model, config, schema: schema) do
            {:ok, response_text, _usage} ->
              case Jason.decode(response_text) do
                {:ok, parsed} -> {:ok, parsed}
                {:error, err} -> {:error, "JSON decode failed: #{inspect(err)}"}
              end

            {:error, reason} ->
              {:error, reason}
          end

        send(worker_pid, {:direct_query_result, query_id, result})
      end)

      pending = Map.put(state.pending_subcalls, query_id, from)
      {:noreply, %{state | pending_subcalls: pending}}
    end
  end

  def handle_call({:spawn_subcall, text, model_size}, from, state) do
    model =
      if model_size == :large,
        do: state.config.model_large,
        else: state.config.model_small

    cond do
      state.depth >= state.config.max_depth ->
        {:reply, {:error, "Maximum recursion depth (#{state.config.max_depth}) exceeded"}, state}

      map_size(state.pending_subcalls) >= state.config.max_concurrent_subcalls ->
        {:reply,
         {:error, "Max concurrent subcalls (#{state.config.max_concurrent_subcalls}) reached"},
         state}

      true ->
        child_span_id = RLM.Span.generate_id()

        emit_telemetry([:rlm, :subcall, :spawn], %{}, state, %{
          child_span_id: child_span_id,
          child_depth: state.depth + 1,
          context_bytes: byte_size(text),
          model_size: model_size
        })

        child_opts = [
          span_id: child_span_id,
          context: text,
          query: text,
          model: model,
          config: state.config,
          depth: state.depth + 1,
          parent_span_id: state.span_id,
          run_id: state.run_id,
          caller: self()
        ]

        case DynamicSupervisor.start_child(RLM.WorkerSup, {RLM.Worker, child_opts}) do
          {:ok, _child_pid} ->
            pending = Map.put(state.pending_subcalls, child_span_id, from)
            {:noreply, %{state | pending_subcalls: pending}}

          {:error, reason} ->
            {:reply, {:error, "Failed to spawn subcall: #{inspect(reason)}"}, state}
        end
    end
  end

  # -- Private --

  defp start_async_eval(state, response, code, reasoning, llm_duration, usage, iter_start) do
    assistant_msg = %{role: :assistant, content: response}

    emit_telemetry([:rlm, :eval, :start], %{}, state, %{
      code: code,
      iteration: state.iteration
    })

    worker_pid = self()
    code_start = System.monotonic_time(:millisecond)

    # Spawn eval asynchronously so the Worker can handle subcall requests.
    # NOTE: RLM.Eval.run uses Code.eval_string — this is the intentional REPL
    # mechanism for the RLM architecture. See RLM.Eval module docs.
    spawn(fn ->
      result =
        RLM.Eval.run(code, state.bindings,
          timeout: state.config.eval_timeout,
          worker_pid: worker_pid,
          bindings_info: RLM.Helpers.list_bindings(state.bindings),
          cwd: state.cwd
        )

      send(worker_pid, {:eval_complete, result})
    end)

    eval_context = %{
      code: code,
      reasoning: reasoning,
      assistant_msg: assistant_msg,
      llm_duration: llm_duration,
      usage: usage,
      iter_start: iter_start,
      code_start: code_start
    }

    {:noreply, %{state | eval_context: eval_context}}
  end

  defp complete(state, result) do
    duration = System.monotonic_time(:millisecond) - state.started_at
    status = if match?({:ok, _}, result), do: :ok, else: :error

    result_preview =
      case result do
        {:ok, val} -> inspect(val) |> String.slice(0, 500)
        {:error, reason} -> inspect(reason) |> String.slice(0, 500)
      end

    if state.keep_alive do
      # Keep-alive mode: reply to caller, reset to idle, emit turn:complete
      emit_telemetry(
        [:rlm, :turn, :complete],
        %{
          duration_ms: duration,
          total_iterations: state.iteration
        },
        state,
        %{
          status: status,
          result_preview: result_preview
        }
      )

      if state.pending_from do
        GenServer.reply(state.pending_from, result)
      else
        Logger.warning(
          "keep_alive turn completed but no pending caller — caller may have timed out",
          span_id: state.span_id,
          result: inspect(result, limit: 200)
        )
      end

      {:noreply,
       %{
         state
         | status: :idle,
           result: nil,
           pending_from: nil,
           eval_context: nil,
           iteration: 0,
           prev_codes: []
       }}
    else
      # One-shot mode: emit node:stop, notify caller, terminate
      emit_telemetry(
        [:rlm, :node, :stop],
        %{
          duration_ms: duration,
          total_iterations: state.iteration
        },
        state,
        %{
          status: status,
          result_preview: result_preview
        }
      )

      if state.caller do
        send(state.caller, {:rlm_result, state.span_id, result})
      end

      {:stop, :normal, %{state | status: status, result: result}}
    end
  end

  defp emit_iteration_stop(
         state,
         iter_duration,
         code,
         stdout,
         usage,
         llm_duration,
         eval_status \\ :skipped
       ) do
    emit_telemetry([:rlm, :iteration, :stop], %{duration_ms: iter_duration}, state, %{
      iteration: state.iteration - 1,
      code: code,
      stdout_preview: String.slice(stdout || "", 0, 500),
      stdout_bytes: byte_size(stdout || ""),
      eval_status: eval_status,
      eval_duration_ms: 0,
      result_preview: "",
      final_answer: nil,
      bindings_snapshot: RLM.Helpers.list_bindings(state.bindings),
      subcalls_spawned: 0,
      llm_prompt_tokens: usage.prompt_tokens,
      llm_completion_tokens: usage.completion_tokens,
      llm_duration_ms: llm_duration
    })
  end

  defp maybe_compact(state) do
    estimated_tokens = estimate_tokens(state.history)
    threshold = trunc(context_window_for_model(state) * 0.8)

    if estimated_tokens > threshold and length(state.history) > 2 do
      [system_msg | rest] = state.history
      serialized = serialize_history(rest)
      existing = Keyword.get(state.bindings, :compacted_history, "")
      combined = join_compacted(existing, serialized)

      preview =
        RLM.Truncate.truncate(combined,
          head: state.config.truncation_head,
          tail: state.config.truncation_tail
        )

      emit_telemetry(
        [:rlm, :compaction, :run],
        %{
          before_tokens: estimated_tokens,
          after_tokens: 0
        },
        state,
        %{history_bytes_compacted: byte_size(serialized)}
      )

      addendum = RLM.Prompt.build_compaction_addendum(preview)

      %{
        state
        | history: [system_msg, %{role: :user, content: addendum}],
          bindings: Keyword.put(state.bindings, :compacted_history, combined)
      }
    else
      state
    end
  end

  defp maybe_nudge(state) do
    if length(state.prev_codes) >= 3 and codes_similar?(state.prev_codes) do
      nudge = RLM.Prompt.build_nudge_message()
      %{state | history: state.history ++ [nudge], prev_codes: []}
    else
      state
    end
  end

  defp codes_similar?([a, b, c | _]) do
    similarity(a, b) > 0.85 and similarity(b, c) > 0.85
  end

  defp codes_similar?(_), do: false

  defp similarity(a, b) do
    a_set = a |> String.split() |> MapSet.new()
    b_set = b |> String.split() |> MapSet.new()
    intersection = MapSet.intersection(a_set, b_set) |> MapSet.size()
    union = MapSet.union(a_set, b_set) |> MapSet.size()
    if union == 0, do: 1.0, else: intersection / union
  end

  defp estimate_tokens(history) do
    history
    |> Enum.map(fn %{content: c} -> div(String.length(c), 4) end)
    |> Enum.sum()
  end

  defp context_window_for_model(state) do
    if state.model == state.config.model_large do
      state.config.context_window_tokens_large
    else
      state.config.context_window_tokens_small
    end
  end

  defp serialize_history(messages) do
    Enum.map_join(messages, "\n---\n", fn %{role: role, content: content} ->
      "[#{role}]\n#{content}"
    end)
  end

  defp join_compacted("", new), do: new
  defp join_compacted(existing, new), do: existing <> "\n===\n" <> new

  defp emit_telemetry(event, measurements, state, extra_metadata) do
    base = %{
      span_id: state.span_id,
      parent_span_id: state.parent_span_id,
      run_id: state.run_id,
      depth: state.depth,
      model: state.model
    }

    :telemetry.execute(event, measurements, Map.merge(base, extra_metadata))
  end
end
