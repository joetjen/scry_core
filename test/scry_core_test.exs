defmodule ScryCoreTest do
  use ExUnit.Case, async: true

  alias ScryCore.Query

  test "parse/1 is the same pipeline ScryCore.Actions produces by hand" do
    assert {:ok, %Query{} = q} = ScryCore.parse(~s(SELECT users WHERE age > 30 { name }))
    assert q.source == ["users"]
    assert q.wheres == [{:cmp, :gt, ["age"], 30}]
    assert q.select == [{:field, ["name"]}]
  end

  test "a syntax error surfaces as {:error, _}, not a raise" do
    assert {:error, _reason} = ScryCore.parse("not a scry query at all {{{")
  end
end
