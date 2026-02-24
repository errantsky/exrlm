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
  `Node.alive?/0`, call those directly from the `Node` module.
  """

  @default_name :rlm
  @default_cookie :rlm_dev

  @doc """
  Start distribution on the current node with short names.

  Reads `RLM_NODE_NAME` and `RLM_COOKIE` environment variables,
  falling back to `:rlm` and `:rlm_dev` respectively.

  Returns `{:ok, node_name}` if distribution starts (or was already
  started), or `{:error, reason}` on failure.

  ## Options

    * `:name` — atom node name (default: from `RLM_NODE_NAME` env or `:rlm`)
    * `:cookie` — atom cookie (default: from `RLM_COOKIE` env or `:rlm_dev`)
  """
  @spec start(keyword()) :: {:ok, node()} | {:error, term()}
  def start(opts \\ []) do
    if Node.alive?() do
      {:ok, Node.self()}
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

  Returns a map with keys: `:node`, `:alive`, `:cookie`,
  `:connected_nodes`, `:visible_nodes`, `:hidden_nodes`.
  """
  @spec info() :: map()
  def info do
    %{
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

  Uses the modern `erpc` module (OTP 23+) which provides structured
  error reporting instead of opaque `{:badrpc, reason}` tuples.

  ## Examples

      iex> RLM.Node.rpc(:rlm@server, RLM, :run, ["data", "summarize"])
      {:ok, "summary", "run-abc123"}

      iex> RLM.Node.rpc(:nonexistent@nowhere, Kernel, :+, [1, 2])
      {:error, {:rpc_failed, :noconnection}}
  """
  @spec rpc(node(), module(), atom(), list()) :: term()
  def rpc(node, mod, fun, args)
      when is_atom(node) and is_atom(mod) and is_atom(fun) and is_list(args) do
    :erpc.call(node, mod, fun, args)
  rescue
    e in ErlangError ->
      {:error, {:rpc_failed, e.original}}
  end

  defp node_name_from_env do
    case System.get_env("RLM_NODE_NAME") do
      nil -> @default_name
      name -> String.to_atom(name)
    end
  end

  defp cookie_from_env do
    case System.get_env("RLM_COOKIE") do
      nil -> @default_cookie
      cookie -> String.to_atom(cookie)
    end
  end
end
