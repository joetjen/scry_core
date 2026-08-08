defmodule Scry.Core.RowTest do
  @moduledoc """
  `Scry.Core.Row` -- the compact positional row representation. Covers
  `build_index/1`/`new/2`'s basic round-trip, a shared index reused
  across several rows (the whole point: no per-row index rebuild), and
  the deliberate, load-bearing asymmetry from a plain map row: `fetch!/2`
  *raises* on a missing column rather than returning `nil`.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.Row

  test "new/2 + fetch!/2 round-trips a row's own columns, from a list or a tuple" do
    index = Row.build_index(["id", "name", "status"])

    from_list = Row.new(index, [1, "bob", "active"])
    from_tuple = Row.new(index, {1, "bob", "active"})

    for row <- [from_list, from_tuple] do
      assert Row.fetch!(row, "id") == 1
      assert Row.fetch!(row, "name") == "bob"
      assert Row.fetch!(row, "status") == "active"
    end
  end

  test "the same index value is reused, unmodified, across every row from one fetch" do
    index = Row.build_index(["id", "age"])

    rows =
      Enum.map([{1, 10}, {2, 20}, {3, 30}], fn values -> Row.new(index, values) end)

    assert Enum.map(rows, &Row.fetch!(&1, "age")) == [10, 20, 30]
    assert Enum.all?(rows, fn %Row{index: i} -> i == index end)
  end

  test "fetch!/2 raises KeyError, not nil, for a column outside the index" do
    row = Row.new(Row.build_index(["id"]), [1])

    assert_raise KeyError, fn -> Row.fetch!(row, "missing") end
  end

  test "to_map/1 converts back to an ordinary string-keyed map" do
    row = Row.new(Row.build_index(["id", "name"]), [7, "ada"])

    assert Row.to_map(row) == %{"id" => 7, "name" => "ada"}
  end

  test "two rows built from the same index and equal values are structurally equal" do
    index = Row.build_index(["a", "b"])

    assert Row.new(index, [1, 2]) == Row.new(index, [1, 2])
    refute Row.new(index, [1, 2]) == Row.new(index, [1, 3])
  end
end
