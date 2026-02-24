defmodule RLM.NodeTest do
  use ExUnit.Case, async: true

  describe "info/0" do
    test "returns a map with all expected keys" do
      info = RLM.Node.info()

      assert is_map(info)
      assert Map.has_key?(info, :node)
      assert Map.has_key?(info, :alive)
      assert Map.has_key?(info, :cookie)
      assert Map.has_key?(info, :connected_nodes)
      assert Map.has_key?(info, :visible_nodes)
      assert Map.has_key?(info, :hidden_nodes)
    end

    test "alive status is consistent with Node.alive?/0" do
      assert RLM.Node.info().alive == Node.alive?()
    end

    test "node lists are all lists" do
      info = RLM.Node.info()
      assert is_list(info.connected_nodes)
      assert is_list(info.visible_nodes)
      assert is_list(info.hidden_nodes)
    end
  end

  describe "start/1" do
    test "returns {:ok, node} when already alive" do
      if Node.alive?() do
        assert {:ok, node} = RLM.Node.start()
        assert node == Node.self()
      end
    end
  end

  describe "rpc/4" do
    test "returns error tuple for unreachable node" do
      result = RLM.Node.rpc(:nonexistent@nowhere, Kernel, :+, [1, 2])
      assert {:error, {:rpc_failed, _reason}} = result
    end

    test "calls function on self when distribution is active" do
      if Node.alive?() do
        assert 3 = RLM.Node.rpc(Node.self(), Kernel, :+, [1, 2])
      end
    end
  end
end
