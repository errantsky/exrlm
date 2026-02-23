defmodule RLM.Node do
  @moduledoc """
  Distributed Erlang node management for RLM.

  Provides helpers to start the current VM as a named node so that remote
  IEx sessions can connect via `--remsh`, and utility functions to inspect
  cluster state.

  ## Development mode

  When running via `iex -S mix`, distribution is not started by default.
  Call `RLM.Node.start/0` (or pass `--sname rlm` on the command line)
  to enable it:

      iex> RLM.Node.start()
      {:ok, :rlm@hostname}

  Then from another terminal:

      iex --sname client --cookie rlm_dev --remsh rlm@$(hostname -s)

  ## Release mode

  Releases produced by `mix release` are pre-configured with node naming
  via `rel/env.sh.eex`. The server starts as `rlm@hostname` automatically.
  Connect with:

      bin/rlm remote

  Or from a standalone IEx:

      iex --sname client --cookie <cookie> --remsh rlm@<host>

  ## Programmatic connection

      iex> RLM.Node.connect(:rlm@server1)
      true
  """

  @default_name :rlm
  @default_cookie :rlm_dev

  @doc """
  Start distribution on the current node with short names.

  Uses the node name from the `RLM_NODE_NAME` environment variable,
  or defaults to `:rlm`. Sets the cookie from `RLM_COOKIE` or
  defaults to `:rlm_dev`.

  Returns `{:ok, node_name}` or `{:error, reason}`.

  ## Options

    * `:name` — atom node name (default: `:rlm` or `RLM_NODE_NAME` env var)
    * `:cookie` — atom cookie (default: `:rlm_dev` or `RLM_COOKIE` env var)

  ## Examples

      iex> RLM.Node.start()
      {:ok, :rlm@myhost}

      iex> RLM.Node.start(name: :rlm_test, cookie: :test_secret)
      {:ok, :rlm_test@myhost}
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
  Stop distribution on the current node.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec stop() :: :ok | {:error, term()}
  def stop do
    if Node.alive?() do
      Node.stop()
    else
      {:error, :not_distributed}
    end
  end

  @doc """
  Connect to a remote RLM node.

  Returns `true` on success, `false` on failure, or `:ignored` if the
  local node is not alive (distribution not started).

  ## Examples

      iex> RLM.Node.connect(:rlm@server1)
      true
  """
  @spec connect(node()) :: boolean() | :ignored
  def connect(node) when is_atom(node) do
    Node.connect(node)
  end

  @doc """
  Return information about the current node and cluster.

  ## Example

      iex> RLM.Node.info()
      %{
        node: :rlm@myhost,
        alive: true,
        cookie: :rlm_dev,
        connected_nodes: [:client@myhost],
        visible_nodes: [:client@myhost],
        hidden_nodes: []
      }
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
  Check if the current node is alive (distribution started).
  """
  @spec alive?() :: boolean()
  def alive?, do: Node.alive?()

  @doc """
  Execute an RLM function on a remote node via `:rpc.call/4`.

  Useful for running queries from a client node against a remote RLM server.

  ## Examples

      # From a client node, run a query on the server
      iex> RLM.Node.rpc(:rlm@server, RLM, :run, ["data", "summarize"])
      {:ok, "summary", "run-abc123"}

      # Start a remote session
      iex> RLM.Node.rpc(:rlm@server, RLM, :start_session, [[cwd: "/project"]])
      {:ok, "span-xyz"}
  """
  @spec rpc(node(), module(), atom(), list()) :: term()
  def rpc(node, mod, fun, args) when is_atom(node) and is_atom(mod) and is_atom(fun) do
    case :rpc.call(node, mod, fun, args) do
      {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
      result -> result
    end
  end

  # -------------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------------

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
