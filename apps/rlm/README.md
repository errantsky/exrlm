# RLM — Recursive Language Model Engine

The core engine of the RLM umbrella project. Provides the iterate loop, eval sandbox,
LLM client, filesystem tools, telemetry, and tracing infrastructure.

This app has no web framework dependency. The Phoenix LiveView dashboard lives in
the sibling `rlm_web` app.

## Quick start

```elixir
# One-shot: process data and get an answer
{:ok, answer, run_id} = RLM.run(context, "Summarize the key findings")

# Interactive: multi-turn session with persistent bindings
{:ok, sid} = RLM.start_session(cwd: ".")
{:ok, answer} = RLM.send_message(sid, "List the Elixir files")
```

## Further reading

See the umbrella root [`README.md`](../../README.md) for full usage documentation
and [`docs/GUIDE.html`](../../docs/GUIDE.html) for the comprehensive architecture
reference.
