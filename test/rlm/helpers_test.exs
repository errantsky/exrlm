defmodule RLM.HelpersTest do
  use ExUnit.Case, async: true

  describe "chunks/2" do
    test "splits string into chunks" do
      result = RLM.Helpers.chunks("abcdefghij", 3) |> Enum.to_list()
      assert result == ["abc", "def", "ghi", "j"]
    end

    test "handles string shorter than chunk size" do
      result = RLM.Helpers.chunks("ab", 10) |> Enum.to_list()
      assert result == ["ab"]
    end

    test "handles empty string" do
      result = RLM.Helpers.chunks("", 5) |> Enum.to_list()
      assert result == []
    end

    test "returns a lazy enumerable" do
      stream = RLM.Helpers.chunks("abcdef", 2)
      assert is_function(stream)
    end
  end

  describe "grep/2" do
    test "finds matching lines with string pattern" do
      text = "apple\nbanana\napricot\nblueberry"
      result = RLM.Helpers.grep("ap", text)
      assert [{1, "apple"}, {3, "apricot"}] = result
    end

    test "finds matching lines with regex pattern" do
      text = "cat\ndog\ncow\ndeer"
      result = RLM.Helpers.grep(~r/^c/, text)
      assert [{1, "cat"}, {3, "cow"}] = result
    end

    test "returns empty list when no matches" do
      assert [] = RLM.Helpers.grep("xyz", "abc\ndef")
    end
  end

  describe "preview/2" do
    test "shows short terms unchanged" do
      assert RLM.Helpers.preview(42) == "42"
    end

    test "truncates long strings" do
      long = String.duplicate("x", 1000)
      result = RLM.Helpers.preview(long, 50)
      # 50 + "..."
      assert String.length(result) <= 54
      assert String.ends_with?(result, "...")
    end
  end

  describe "list_bindings/1" do
    test "returns name, type, size, and preview for each binding" do
      bindings = [x: 42, name: "hello", items: [1, 2, 3]]
      result = RLM.Helpers.list_bindings(bindings)

      assert [
               {:x, "integer", _, "42"},
               {:name, "string", 5, "\"hello\""},
               {:items, "list", _, "[1, 2, 3]"}
             ] =
               result
    end
  end
end
