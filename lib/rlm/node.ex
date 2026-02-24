defmodule RLM.Node do
  @moduledoc """
  Distributed Erlang node management for RLM.

  Provides helpers to start distribution on the current VM so remote IEx
  sessions can connect via `--remsh`, and to execute RPC calls against
  remote RLM nodes.

  ## Development mode

      iex> RLM.Node.start()
      {:ok, :rlm@hostname}

  Then from another terminal:

      iex --sname client --cookie rlm_dev --remsh rlm@$(hostname -s)

  ## Release mode

  Releases are pre-configured with node naming via `rel/env.sh.eex`.
  Connect with:

      bin/rlm remote

  For trivial operations like `Node.connect/1`, `Node.stop/0`, and
  `Node.alive?/0`, use the standard Elixir `Node` module directly.
  """

  defmodule Info do
    @moduledoc false
    defstruct [:node, :alive, :cookie, :connected_nodes, :visible_nodes, :hidden_nodes]

    @type t :: %__MODULE__{
            node: node(),
            alive: boolean(),
            cookie: atom(),
            connected_nodes: [node()],
            visible_nodes: [node()],
            hidden_nodes: [node()]
          }
  end

  @default_name :rlm
  @default_cookie :rlm_dev

  @type start_opts :: [name: atom(), cookie: atom()]

  @doc """
  Start distribution on the current node with short names.

  Reads `RLM_NODE_NAME` and `RLM_COOKIE` environment variables,
  falling back to `:rlm` and `:rlm_dev` respectively.

  Returns `{:ok, node_name}` if distribution starts successfully,
  or `{:error, reason}` on failure. If the node is already alive and
  the requested name/cookie match the current configuration, returns
  `{:ok, current_node}`. Returns an error if the node is already alive
  with a different cookie than requested.

  ## Options

    * `:name` — atom node name (default: from `RLM_NODE_NAME` env or `:rlm`)
    * `:cookie` — atom cookie (default: from `RLM_COOKIE` env or `:rlm_dev`)
  """
  @spec start(start_opts()) :: {:ok, node()} | {:error, term()}
  def start(opts \\ []) do
    if Node.alive?() do
      requested_cookie = Keyword.get(opts, :cookie)

      if requested_cookie && requested_cookie != Node.get_cookie() do
        {:error, {:already_started, Node.self(), :cookie_mismatch}}
      else
        {:ok, Node.self()}
      end
    else
      name = Keyword.get(opts, :name, node_name_from_env())
      cookie = Keyword.get(opts, :cookie, cookie_from_env())

      case Node.start(name, name_domain: :shortnames) do
        {:ok, _pid} ->
          Node.set_cookie(cookie)
          {:ok, Node.self()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Return information about the current node and cluster.

  Returns an `%RLM.Node.Info{}` struct with fields: `:node`, `:alive`,
  `:cookie`, `:connected_nodes`, `:visible_nodes`, `:hidden_nodes`.
  """
  @spec info() :: Info.t()
  def info do
    %Info{
      node: Node.self(),
      alive: Node.alive?(),
      cookie: Node.get_cookie(),
      connected_nodes: Node.list(:connected),
      visible_nodes: Node.list(:visible),
      hidden_nodes: Node.list(:hidden)
    }
  end

  @doc """
  Execute a function on a remote node via `:erpc.call/5`.

  Uses the modern `erpc` module (OTP 23+) internally. Connection failures
  and remote exceptions are caught and returned as
  `{:error, {:rpc_failed, reason}}` tuples instead of raising.

  ## Options

  The `timeout` parameter controls the maximum time to wait for the remote
  call to complete (default: `5_000` ms). For long-running calls like
  `RLM.run/3`, pass a longer timeout.

  ## Examples

      iex> RLM.Node.rpc(:rlm@server, RLM, :run, ["data", "summarize"], 120_000)
      {:ok, {:ok, "summary", "run-abc123"}}

      iex> RLM.Node.rpc(:nonexistent@nowhere, Kernel, :+, [1, 2])
      {:error, {:rpc_failed, :noconnection}}
  """
  @spec rpc(node(), module(), atom(), list(), timeout()) ::
          {:ok, term()} | {:error, {:rpc_failed, term()}}
  def rpc(node, mod, fun, args, timeout \\ 5_000)
      when is_atom(node) and is_atom(mod) and is_atom(fun) and is_list(args) do
    {:ok, :erpc.call(node, mod, fun, args, timeout)}
  rescue
    e in ErlangError ->
      {:error, {:rpc_failed, e.original}}

    e ->
      {:error, {:rpc_failed, {e.__struct__, Exception.message(e)}}}
  end

  defp node_name_from_env do
    case System.get_env("RLM_NODE_NAME") do
      nil -> @default_name
      "" -> @default_name
      name -> String.to_atom(name)
    end
  end

  defp cookie_from_env do
    case System.get_env("RLM_COOKIE") do
      nil -> @default_cookie
      "" -> @default_cookie
      cookie -> String.to_atom(cookie)
    end
  end
end
