defmodule ScryCore.QueryTest do
  @moduledoc """
  `ScryCore.Query`'s own composable functional builder API (impl_spec.md
  §7's Layer 1) -- builds a query entirely in Elixir, then confirms it
  executes identically to the equivalent hand-written struct, and (for
  the constructs that also parse) identically to the equivalent query
  text through `ScryCore.parse/1` -- the same "both front ends converge
  on one struct" property that module's own moduledoc has always
  described, exercised for real for the first time here.
  """

  use ExUnit.Case, async: true

  alias ScryCore.Query

  @users [
    %{"name" => "Alice", "age" => 30, "status" => "active"},
    %{"name" => "Bob", "age" => 17, "status" => "active"},
    %{"name" => "Carol", "age" => 65, "status" => "inactive"}
  ]

  defmodule StaticEngine do
    @moduledoc false
    @behaviour ScryCore.EngineBehaviour

    @impl true
    def fetch(data, source) do
      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end
  end

  setup do
    %{conn: %{["users"] => @users}}
  end

  # `ScryCore.Executor.run/3,4` returns `{:ok, ScryCore.Cursor.t()}` now,
  # not `{:ok, [row()]}` -- drains it back to this suite's own
  # long-established shape, converting a lazily-raised `ScryCore.
  # Executor.QueryError` back into the classic `{:error, reason}` tuple.
  defp materialize({:error, _} = err), do: err

  defp materialize({:ok, cursor}) do
    {:ok, ScryCore.Cursor.to_list(cursor)}
  rescue
    e in ScryCore.Executor.QueryError -> {:error, e.reason}
  end

  test "new/1 starts an otherwise-empty query against source" do
    query = Query.new(["users"])
    assert query.source == ["users"]
    assert %Query{} = query
    assert query.wheres == []
    assert query.select == []
  end

  test "where/2 accumulates predicates, ANDed, same as ScryCore.parse/1 would build", %{
    conn: conn
  } do
    built =
      Query.new(["users"])
      |> Query.where({:cmp, :gt, ["age"], 18})
      |> Query.select([{:field, ["name"]}])

    assert {:ok, parsed} = ScryCore.parse(~s(SELECT users WHERE age > 18 { name }))
    assert built.wheres == parsed.wheres

    assert {:ok, rows} = ScryCore.Executor.run(built, StaticEngine, conn) |> materialize()
    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "where/2 called twice ANDs both predicates", %{conn: conn} do
    built =
      Query.new(["users"])
      |> Query.where({:cmp, :gt, ["age"], 18})
      |> Query.where({:cmp, :eq, ["status"], "active"})
      |> Query.select([{:field, ["name"]}])

    assert {:ok, rows} = ScryCore.Executor.run(built, StaticEngine, conn) |> materialize()
    assert rows == [%{"name" => "Alice"}]
  end

  test "group_by/2 + having/2 + an aggregate, executed end to end", %{conn: conn} do
    built =
      Query.new(["users"])
      |> Query.group_by([["status"]])
      |> Query.having({:cmp, :gt, {:call, "count", [{:field, ["name"]}]}, 1})
      |> Query.select([
        {:field, ["status"]},
        {:computed, "total", {:call, "count", [{:field, ["name"]}]}}
      ])

    assert {:ok, rows} = ScryCore.Executor.run(built, StaticEngine, conn) |> materialize()
    assert rows == [%{"status" => "active", "total" => 2}]
  end

  test "distinct/1 defaults to true, distinct/2 sets it explicitly" do
    assert Query.new(["users"]).distinct == false
    assert Query.new(["users"]) |> Query.distinct() |> Map.get(:distinct) == true
    assert Query.new(["users"]) |> Query.distinct(true) |> Map.get(:distinct) == true
    assert Query.new(["users"]) |> Query.distinct(false) |> Map.get(:distinct) == false
  end

  test "order_by/2, limit/2, offset/2, executed end to end", %{conn: conn} do
    built =
      Query.new(["users"])
      |> Query.order_by([{["age"], :desc}])
      |> Query.limit(1)
      |> Query.offset(1)
      |> Query.select([{:field, ["name"]}])

    assert {:ok, rows} = ScryCore.Executor.run(built, StaticEngine, conn) |> materialize()
    assert rows == [%{"name" => "Alice"}]
  end

  test "select/2 sets the projection, same shape ScryCore.parse/1 produces", %{conn: conn} do
    built = Query.new(["users"]) |> Query.select([{:field, ["name"]}, {:field, ["age"]}])
    assert {:ok, parsed} = ScryCore.parse(~s(SELECT users { name, age }))
    assert built.select == parsed.select

    assert {:ok, rows} = ScryCore.Executor.run(built, StaticEngine, conn) |> materialize()

    assert rows == [
             %{"name" => "Alice", "age" => 30},
             %{"name" => "Bob", "age" => 17},
             %{"name" => "Carol", "age" => 65}
           ]
  end

  test "group_by_rollup/2 and group_by_cube/2 build a query that executes for real, subtotals included",
       %{conn: conn} do
    select = [
      {:field, ["status"]},
      {:computed, "total", {:call, "count", [{:field, ["name"]}]}}
    ]

    rollup =
      Query.new(["users"]) |> Query.group_by_rollup([["status"]]) |> Query.select(select)

    assert rollup.group_mode == :rollup
    assert {:ok, rollup_rows} = ScryCore.Executor.run(rollup, StaticEngine, conn) |> materialize()

    assert Enum.sort(rollup_rows) ==
             Enum.sort([
               %{"status" => "active", "total" => 2},
               %{"status" => "inactive", "total" => 1},
               %{"status" => nil, "total" => 3}
             ])

    cube = Query.new(["users"]) |> Query.group_by_cube([["status"]]) |> Query.select(select)

    assert cube.group_mode == :cube
    assert {:ok, cube_rows} = ScryCore.Executor.run(cube, StaticEngine, conn) |> materialize()
    # A single-column CUBE has the same two grouping levels ROLLUP does
    # (the full column, then the grand total) -- CUBE's own extra
    # subsets only appear starting at two columns.
    assert Enum.sort(cube_rows) == Enum.sort(rollup_rows)
  end

  test "a fully hand-built query and the equivalent parsed query execute identically", %{
    conn: conn
  } do
    built =
      Query.new(["users"])
      |> Query.where({:cmp, :gt, ["age"], 18})
      |> Query.order_by([{["name"], :asc}])
      |> Query.limit(2)
      |> Query.select([{:field, ["name"]}])

    assert {:ok, parsed} =
             ScryCore.parse(~s(SELECT users WHERE age > 18 ORDER BY name LIMIT 2 { name }))

    assert {:ok, built_rows} = ScryCore.Executor.run(built, StaticEngine, conn) |> materialize()
    assert {:ok, parsed_rows} = ScryCore.Executor.run(parsed, StaticEngine, conn) |> materialize()
    assert built_rows == parsed_rows
  end
end
