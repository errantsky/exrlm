defmodule RLM.NodeTest do
  use ExUnit.Case, async: false

  # Tests mutate global VM distribution state (Node.start/Node.stop),
  # so they must run sequentially (async: false).

  setup_all do
    # EPMD must be running for Node.start/2 to work.
    # In `mix test` (without --sname), EPMD isn't started automatically.
    System.cmd("epmd", ["-daemon"])
    Process.sleep(200)
    :ok
  end

  setup do
    if Node.alive?(), do: Node.stop()
    :ok
  end

  describe "info/0" do
    test "returns an Info struct with all expected fields" do
      %RLM.Node.Info{} = info = RLM.Node.info()

      assert is_atom(info.node)
      assert is_boolean(info.alive)
      assert is_atom(info.cookie)
      assert is_list(info.connected_nodes)
      assert is_list(info.visible_nodes)
      assert is_list(info.hidden_nodes)
    end

    test "alive status is consistent with Node.alive?/0" do
      assert RLM.Node.info().alive == Node.alive?()
    end

    test "reports alive after distribution starts" do
      {:ok, _} = RLM.Node.start(name: :rlm_info_test)
      info = RLM.Node.info()
      assert info.alive
      assert info.node |> to_string() |> String.starts_with?("rlm_info_test@")
    end
  end

  describe "start/1" do
    test "starts distribution and returns {:ok, node}" do
      refute Node.alive?()
      assert {:ok, node_name} = RLM.Node.start(name: :rlm_start_test)
      assert Node.alive?()
      assert node_name == Node.self()
      assert node_name |> to_string() |> String.starts_with?("rlm_start_test@")
    end

    test "sets the cookie after starting" do
      custom_cookie = :rlm_test_cookie_abc
      {:ok, _} = RLM.Node.start(name: :rlm_cookie_test, cookie: custom_cookie)
      assert Node.get_cookie() == custom_cookie
    end

    test "returns {:ok, node} when already alive with compatible config" do
      {:ok, _} = RLM.Node.start(name: :rlm_idempotent_test)
      assert {:ok, node} = RLM.Node.start()
      assert node == Node.self()
    end

    test "returns error when already alive with a different cookie" do
      {:ok, _} = RLM.Node.start(name: :rlm_mismatch_test, cookie: :cookie_a)

      assert {:error, {:already_started, _, :cookie_mismatch}} =
               RLM.Node.start(cookie: :cookie_b)
    end

    test "reads RLM_NODE_NAME from environment" do
      System.put_env("RLM_NODE_NAME", "env_name_test")
      {:ok, node} = RLM.Node.start()
      assert node |> to_string() |> String.starts_with?("env_name_test@")
    after
      System.delete_env("RLM_NODE_NAME")
    end

    test "reads RLM_COOKIE from environment" do
      System.put_env("RLM_COOKIE", "env_cookie_test")
      {:ok, _} = RLM.Node.start(name: :rlm_env_cookie_test)
      assert Node.get_cookie() == :env_cookie_test
    after
      System.delete_env("RLM_COOKIE")
    end

    test "ignores empty RLM_NODE_NAME and uses default" do
      System.put_env("RLM_NODE_NAME", "")
      {:ok, node} = RLM.Node.start()
      assert node |> to_string() |> String.starts_with?("rlm@")
    after
      System.delete_env("RLM_NODE_NAME")
    end
  end

  describe "rpc/5" do
    test "returns {:ok, result} for successful call on self" do
      {:ok, _} = RLM.Node.start(name: :rlm_rpc_self_test)
      assert {:ok, 3} = RLM.Node.rpc(Node.self(), Kernel, :+, [1, 2])
    end

    test "returns {:ok, result} for complex return values" do
      {:ok, _} = RLM.Node.start(name: :rlm_rpc_complex_test)
      assert {:ok, %{a: 1, b: 2}} = RLM.Node.rpc(Node.self(), Map, :new, [[a: 1, b: 2]])
    end

    test "returns error tuple for unreachable node" do
      result = RLM.Node.rpc(:nonexistent@nowhere, Kernel, :+, [1, 2])
      assert {:error, {:rpc_failed, _reason}} = result
    end

    test "catches remote exceptions" do
      {:ok, _} = RLM.Node.start(name: :rlm_rpc_error_test)

      # Remote exceptions arrive as {:exception, reason, stacktrace} via :erpc
      assert {:error, {:rpc_failed, {:exception, :badarg, stacktrace}}} =
               RLM.Node.rpc(Node.self(), String, :to_integer, ["not_a_number"])

      assert is_list(stacktrace)
    end

    test "respects timeout parameter" do
      {:ok, _} = RLM.Node.start(name: :rlm_rpc_timeout_test)

      # A 1ms timeout on a 100ms sleep should fail
      assert {:error, {:rpc_failed, {:erpc, :timeout}}} =
               RLM.Node.rpc(Node.self(), Process, :sleep, [100], 1)
    end

    test "raises FunctionClauseError for non-atom module" do
      assert_raise FunctionClauseError, fn ->
        RLM.Node.rpc(:some_node, "NotAnAtom", :fun, [])
      end
    end
  end
end
