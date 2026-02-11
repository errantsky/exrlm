defmodule RLM.TruncateTest do
  use ExUnit.Case, async: true

  describe "truncate/2" do
    test "returns string unchanged when shorter than head + tail" do
      assert RLM.Truncate.truncate("short", head: 100, tail: 100) == "short"
    end

    test "truncates long strings with head and tail" do
      long = String.duplicate("a", 100)
      result = RLM.Truncate.truncate(long, head: 10, tail: 10)

      assert String.starts_with?(result, String.duplicate("a", 10))
      assert String.ends_with?(result, String.duplicate("a", 10))
      assert result =~ "80 characters omitted"
    end

    test "handles empty string" do
      assert RLM.Truncate.truncate("", head: 10, tail: 10) == ""
    end

    test "uses default values" do
      short = "hello"
      assert RLM.Truncate.truncate(short) == "hello"
    end
  end
end
