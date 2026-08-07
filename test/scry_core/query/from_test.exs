defmodule ScryCore.Query.FromTest do
  @moduledoc """
  `ScryCore.Query.from/2` (impl_spec.md §7 Layer 2) -- confirms a
  macro-built query executes identically to the equivalent text query,
  the same "both front ends converge on one struct" property `query_
  test.exs` already confirms for Layer 1.
  """

  use ExUnit.Case, async: true

  import ScryCore.Query

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
    assert {:ok, parsed} = ScryCore.parse(~s(SELECT users WHERE age > 18 { name: name }))
    assert built.select == parsed.select
    assert built.wheres == parsed.wheres

    assert {:ok, built_rows} = ScryCore.Executor.run(built, StaticEngine, conn)
    assert {:ok, parsed_rows} = ScryCore.Executor.run(parsed, StaticEngine, conn)
    assert built_rows == parsed_rows
    assert built_rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "^pin resolves through ScryCore.Executor.run/4's own params argument", %{conn: conn} do
    min_age = 18
    query = from(u in "users", where: u.age > ^min_age, select: %{name: u.name})

    assert {:ok, rows} =
             ScryCore.Executor.run(query, StaticEngine, conn, %{"min_age" => min_age})

    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "group_by + having + an aggregate, executed end to end", %{conn: conn} do
    query =
      from(u in "users",
        group_by: [u.status],
        having: count(u.name) > 1,
        select: %{status: u.status, total: count(u.name)}
      )

    assert {:ok, rows} = ScryCore.Executor.run(query, StaticEngine, conn)
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

    assert {:ok, rows} = ScryCore.Executor.run(query, StaticEngine, conn)
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

    assert {:ok, rows} = ScryCore.Executor.run(query, StaticEngine, conn)

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

    assert {:ok, rows} = ScryCore.Executor.run(query, StaticEngine, conn)
    assert Enum.sort(rows) == Enum.sort([%{"status" => "active"}, %{"status" => "inactive"}])
  end

  test "an unrecognized from/2 keyword raises a clear compile-time error" do
    assert_raise ArgumentError, ~r/doesn't recognize `bogus:`/, fn ->
      Code.eval_quoted(
        quote do
          import ScryCore.Query
          from(u in "users", bogus: 1, select: %{name: u.name})
        end
      )
    end
  end

  test "a select value that isn't a map literal raises a clear compile-time error" do
    assert_raise ArgumentError, ~r/select:` must be a map literal/, fn ->
      Code.eval_quoted(
        quote do
          import ScryCore.Query
          from(u in "users", select: [:name])
        end
      )
    end
  end

  describe "nested from (correlation)" do
    test "impl_spec.md §7's own worked example, executed end to end", %{conn: conn} do
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

      assert {:ok, rows} = ScryCore.Executor.run(query, StaticEngine, conn)

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

      assert {:ok, rows} = ScryCore.Executor.run(query, StaticEngine, conn)

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
            import ScryCore.Query

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
                         import ScryCore.Query
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
end
