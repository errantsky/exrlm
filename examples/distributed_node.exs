# examples/distributed_node.exs
#
# Demonstrates running RLM as a named Erlang node and connecting
# from a separate IEx session.
#
# This example is meant to be read and run manually in two terminals,
# not executed as a script. It documents the standard workflow.

IO.puts("""
=============================================================
  RLM Distributed Node — Example Workflow
=============================================================

STEP 1: Start the RLM server as a named node
---------------------------------------------

  Terminal 1 (server):

    # Development mode (with IEx):
    iex --sname rlm --cookie rlm_dev -S mix

    # Or start distribution after launching IEx:
    iex -S mix
    iex> RLM.Node.start()
    {:ok, :rlm@myhost}

    # Or via a release:
    MIX_ENV=prod mix release rlm
    _build/prod/rel/rlm/bin/rlm start


STEP 2: Connect from a client
-------------------------------

  Terminal 2 (client) — choose one approach:

  A) Remote shell (full access to the server's IEx):

    iex --sname client --cookie rlm_dev --remsh rlm@myhost

    # Now you're running inside the server process.
    # All RLM.IEx helpers are available:
    iex> import RLM.IEx
    iex> {session, _} = start_chat("List files in the current directory")
    iex> chat(session, "Now read the README and summarize it")

  B) Separate node with RPC:

    iex --sname client --cookie rlm_dev -S mix

    iex> Node.connect(:rlm@myhost)
    true

    # Run a query on the remote server:
    iex> RLM.IEx.remote(:rlm@myhost, "Summarize this", context: "Hello world")

    # Or use RPC directly:
    iex> RLM.Node.rpc(:rlm@myhost, RLM, :run, ["data", "analyze this"])

  C) Release remote shell:

    _build/prod/rel/rlm/bin/rlm remote


STEP 3: Verify connectivity
-----------------------------

  On either node:

    iex> RLM.Node.info()
    %{
      node: :rlm@myhost,
      alive: true,
      cookie: :rlm_dev,
      connected_nodes: [:client@myhost],
      ...
    }

    iex> Node.list()
    [:client@myhost]


NOTES
-----

  - Short names (--sname) work on the same machine or local network.
    For cross-network, use --name with fully qualified domain names.

  - All nodes must share the same cookie value.

  - The server's Phoenix dashboard remains accessible at
    http://localhost:4000 regardless of distribution mode.

  - Environment variables for production:
      RLM_NODE_NAME=rlm      (node name, default: rlm)
      RLM_COOKIE=secret       (cookie, default: rlm_dev)
      CLAUDE_API_KEY=sk-...   (required for LLM calls)
""")
