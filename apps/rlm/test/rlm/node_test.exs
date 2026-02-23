defmodule RLM.NodeTest do
  use ExUnit.Case, async: true

  describe "info/0" do
    test "returns a map with expected keys" do
      info = RLM.Node.info()

      assert is_map(info)
      assert Map.has_key?(info, :node)
      assert Map.has_key?(info, :alive)
      assert Map.has_key?(info, :cookie)
      assert Map.has_key?(info, :connected_nodes)
      assert Map.has_key?(info, :visible_nodes)
      assert Map.has_key?(info, :hidden_nodes)
    end

    test "reports alive status consistent with Node.alive?" do
      info = RLM.Node.info()
      assert info.alive == Node.alive?()
    end
  end

  describe "alive?/0" do
    test "returns a boolean" do
      assert is_boolean(RLM.Node.alive?())
    end
  end

  describe "start/1 when already alive" do
    test "returns {:ok, node} if distribution is already started" do
      if Node.alive?() do
        assert {:ok, node} = RLM.Node.start()
        assert node == Node.self()
      end
    end
  end

  describe "stop/0 when not distributed" do
    test "returns error when not distributed" do
      unless Node.alive?() do
        assert {:error, :not_distributed} = RLM.Node.stop()
      end
    end
  end

  describe "rpc/4" do
    test "calls a local function when given Node.self()" do
      if Node.alive?() do
        result = RLM.Node.rpc(Node.self(), Kernel, :+, [1, 2])
        assert result == 3
      end
    end

    test "returns error tuple for unreachable node" do
      result = RLM.Node.rpc(:nonexistent@nowhere, Kernel, :+, [1, 2])
      assert {:error, {:rpc_failed, _reason}} = result
    end
  end
end
