defmodule Scry.Core.Query.FromTest do
  @moduledoc """
  `Scry.Core.Query.from/2` (its own Layer 2) -- confirms a
  macro-built query executes identically to the equivalent text query,
  the same "both front ends converge on one struct" property `query_
  test.exs` already confirms for Layer 1.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.Test.ReferenceEngine, as: StaticEngine

  import Scry.Core.Query

  # `Scry.Core.Executor.run/3,4` returns `{:ok, Scry.Core.Cursor.t()}` now,
  # not `{:ok, [row()]}` -- drains it back to this suite's own
  # long-established shape, converting a lazily-raised `Scry.Core.
  # Executor.QueryError` back into the classic `{:error, reason}` tuple.
  defp materialize({:error, _} = err), do: err

  defp materialize({:ok, cursor}) do
    {:ok, Scry.Core.Cursor.to_list(cursor)}
  rescue
    e in Scry.Core.Executor.QueryError -> {:error, e.reason}
  end

  @users [
    %{"id" => 1, "name" => "Alice", "age" => 30, "status" => "active"},
    %{"id" => 2, "name" => "Bob", "age" => 17, "status" => "active"},
    %{"id" => 3, "name" => "Carol", "age" => 65, "status" => "inactive"}
  ]

  @orders [
    %{"id" => 10, "user_id" => 1, "total" => 80},
    %{"id" => 11, "user_id" => 1, "total" => 20},
    %{"id" => 12, "user_id" => 3, "total" => 5}
  ]

  setup do
    %{conn: %{["users"] => @users, ["orders"] => @orders}}
  end

  test "a bare source string is wrapped into a single-element source path" do
    query = from(u in "users", select: %{name: u.name})
    assert query.source == ["users"]
  end

  test "where + select, executed identically to the equivalent text query", %{conn: conn} do
    built = from(u in "users", where: u.age > 18, select: %{name: u.name})
    assert {:ok, parsed} = Scry.Core.parse(~s(SELECT users WHERE age > 18 { name: name }))
    assert built.select == parsed.select
    assert built.wheres == parsed.wheres

    assert {:ok, built_rows} = Scry.Core.Executor.run(built, StaticEngine, conn) |> materialize()

    assert {:ok, parsed_rows} =
             Scry.Core.Executor.run(parsed, StaticEngine, conn) |> materialize()

    assert built_rows == parsed_rows
    assert built_rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "^pin resolves through Scry.Core.Executor.run/4's own params argument", %{conn: conn} do
    min_age = 18
    query = from(u in "users", where: u.age > ^min_age, select: %{name: u.name})

    assert {:ok, rows} =
             Scry.Core.Executor.run(query, StaticEngine, conn, %{"min_age" => min_age})
             |> materialize()

    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "group_by + having + an aggregate, executed end to end", %{conn: conn} do
    query =
      from(u in "users",
        group_by: [u.status],
        having: count(u.name) > 1,
        select: %{status: u.status, total: count(u.name)}
      )

    assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()
    assert rows == [%{"status" => "active", "total" => 2}]
  end

  test "order_by (asc/desc keyword shorthand) + limit + offset", %{conn: conn} do
    query =
      from(u in "users",
        order_by: [desc: u.age],
        limit: 1,
        offset: 1,
        select: %{name: u.name}
      )

    assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()
    assert rows == [%{"name" => "Alice"}]
  end

  test "cond in a select value, executed end to end", %{conn: conn} do
    query =
      from(u in "users",
        select: %{
          name: u.name,
          bucket:
            cond do
              u.age < 18 -> "minor"
              u.age < 65 -> "adult"
              true -> "senior"
            end
        }
      )

    assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

    assert rows == [
             %{"name" => "Alice", "bucket" => "adult"},
             %{"name" => "Bob", "bucket" => "minor"},
             %{"name" => "Carol", "bucket" => "senior"}
           ]
  end

  test "distinct/2 and an in predicate", %{conn: conn} do
    query =
      from(u in "users",
        where: u.status in ["active", "inactive"],
        distinct: true,
        select: %{status: u.status}
      )

    assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()
    assert Enum.sort(rows) == Enum.sort([%{"status" => "active"}, %{"status" => "inactive"}])
  end

  test "an unrecognized from/2 keyword raises a clear compile-time error" do
    assert_raise ArgumentError, ~r/doesn't recognize `bogus:`/, fn ->
      Code.eval_quoted(
        quote do
          import Scry.Core.Query
          from(u in "users", bogus: 1, select: %{name: u.name})
        end
      )
    end
  end

  describe "nested from (correlation)" do
    test "a worked example, executed end to end", %{conn: conn} do
      query =
        from(u in "users",
          where: u.age > 18,
          select: %{
            name: u.name,
            orders:
              from(o in "orders",
                where: o.total > 50 and o.user_id == u.id,
                select: %{id: o.id, total: o.total}
              )
          }
        )

      assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

      assert rows == [
               %{"name" => "Alice", "orders" => [%{"id" => 10, "total" => 80}]},
               %{"name" => "Carol", "orders" => []}
             ]
    end

    test "the nested query's own where correctly correlates to the outer's literal source name",
         %{conn: conn} do
      query =
        from(u in "users",
          select: %{
            name: u.name,
            orders: from(o in "orders", where: o.user_id == u.id, select: %{id: o.id})
          }
        )

      assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

      assert rows == [
               %{"name" => "Alice", "orders" => [%{"id" => 10}, %{"id" => 11}]},
               %{"name" => "Bob", "orders" => []},
               %{"name" => "Carol", "orders" => [%{"id" => 12}]}
             ]
    end

    test "a select: map key that doesn't match the nested from's own source is a clear error" do
      assert_raise ArgumentError, ~r/doesn't match the nested `from`'s own source/, fn ->
        Code.eval_quoted(
          quote do
            import Scry.Core.Query

            from(u in "users",
              select: %{
                wrong_key: from(o in "orders", where: o.user_id == u.id, select: %{id: o.id})
              }
            )
          end
        )
      end
    end

    test "a nested from under a non-compile-time-known outer source is a clear error" do
      assert_raise ArgumentError,
                   ~r/needs its own outer `from`'s source to be a compile-time-known/,
                   fn ->
                     Code.eval_quoted(
                       quote do
                         import Scry.Core.Query
                         source = "users"

                         from(u in source,
                           select: %{
                             orders:
                               from(o in "orders", where: o.user_id == u.id, select: %{id: o.id})
                           }
                         )
                       end
                     )
                   end
    end
  end

  describe "over/2 (window functions)" do
    test "row_number() OVER PARTITION BY ... ORDER BY ..., executed end to end", %{conn: conn} do
      query =
        from(u in "users",
          select: %{
            name: u.name,
            status: u.status,
            rank: over(row_number(), partition_by: [u.status], order_by: [desc: u.age])
          }
        )

      assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

      assert Enum.sort_by(rows, &{&1["status"], &1["rank"]}) == [
               %{"name" => "Alice", "status" => "active", "rank" => 1},
               %{"name" => "Bob", "status" => "active", "rank" => 2},
               %{"name" => "Carol", "status" => "inactive", "rank" => 1}
             ]
    end

    test "the same window expression, built and via text, produce identical results", %{
      conn: conn
    } do
      built =
        from(u in "users",
          select: %{
            rank: over(row_number(), partition_by: [u.status], order_by: [desc: u.age])
          }
        )

      assert {:ok, parsed} =
               Scry.Core.parse(
                 "SELECT users { rank: row_number() OVER PARTITION BY status ORDER BY age DESC }"
               )

      assert built.select == parsed.select

      assert {:ok, built_rows} =
               Scry.Core.Executor.run(built, StaticEngine, conn) |> materialize()

      assert {:ok, parsed_rows} =
               Scry.Core.Executor.run(parsed, StaticEngine, conn) |> materialize()

      assert Enum.sort(built_rows) == Enum.sort(parsed_rows)
    end

    test "a running sum with an explicit frame, executed end to end", %{conn: conn} do
      query =
        from(u in "users",
          where: u.status == "active",
          order_by: [asc: u.name],
          select: %{
            name: u.name,
            running_total:
              over(sum(u.age),
                order_by: [asc: u.name],
                rows_between: {:unbounded_preceding, :current_row}
              )
          }
        )

      assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

      assert rows == [
               %{"name" => "Alice", "running_total" => 30},
               %{"name" => "Bob", "running_total" => 47}
             ]
    end
  end

  describe "list-shaped select" do
    test "bare field paths, executed identically to the equivalent text query", %{conn: conn} do
      built = from(u in "users", select: [u.name, u.age])
      assert {:ok, parsed} = Scry.Core.parse(~s(SELECT users { name, age }))
      assert built.select == parsed.select

      assert {:ok, rows} = Scry.Core.Executor.run(built, StaticEngine, conn) |> materialize()

      assert rows == [
               %{"name" => "Alice", "age" => 30},
               %{"name" => "Bob", "age" => 17},
               %{"name" => "Carol", "age" => 65}
             ]
    end

    test "a bare field mixed with an aliased computed entry", %{conn: conn} do
      query = from(o in "orders", select: [o.id, doubled: o.total * 2])
      assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

      assert rows == [
               %{"id" => 10, "doubled" => 160},
               %{"id" => 11, "doubled" => 40},
               %{"id" => 12, "doubled" => 10}
             ]
    end

    test "a nested from as a bare list item, with no map key to get wrong", %{conn: conn} do
      query =
        from(u in "users",
          select: [
            u.name,
            from(o in "orders", where: o.user_id == u.id, select: [o.id, o.total])
          ]
        )

      assert {:ok, rows} = Scry.Core.Executor.run(query, StaticEngine, conn) |> materialize()

      assert rows == [
               %{
                 "name" => "Alice",
                 "orders" => [%{"id" => 10, "total" => 80}, %{"id" => 11, "total" => 20}]
               },
               %{"name" => "Bob", "orders" => []},
               %{"name" => "Carol", "orders" => [%{"id" => 12, "total" => 5}]}
             ]
    end

    test "an unaliased non-field expression is a clear compile-time error" do
      assert_raise ArgumentError, ~r/doesn't resolve to a bound variable in scope/, fn ->
        Code.eval_quoted(
          quote do
            import Scry.Core.Query
            from(u in "users", select: [u.age * 2])
          end
        )
      end
    end

    test "a select value that's neither a map nor a list is a clear compile-time error" do
      assert_raise ArgumentError, ~r/must be a map literal.*or a list/, fn ->
        Code.eval_quoted(
          quote do
            import Scry.Core.Query
            from(u in "users", select: 5)
          end
        )
      end
    end
  end
end
