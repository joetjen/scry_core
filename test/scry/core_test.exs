defmodule Scry.CoreTest do
  use ExUnit.Case, async: true

  alias Scry.Core.Query

  test "parse/1 is the same pipeline Scry.Core.Actions produces by hand" do
    assert {:ok, %Query{} = q} = Scry.Core.parse(~s(SELECT users WHERE age > 30 { name }))
    assert q.source == ["users"]
    assert q.wheres == [{:cmp, :gt, ["age"], 30}]
    assert q.select == [{:field, ["name"]}]
  end

  test "a syntax error surfaces as {:error, _}, not a raise" do
    assert {:error, _reason} = Scry.Core.parse("not a scry query at all {{{")
  end
end
