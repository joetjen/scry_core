defmodule ScryCore.Query.FromTest do
  @moduledoc """
  `ScryCore.Query.from/2` (impl_spec.md §7 Layer 2, v1) -- confirms a
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
    %{"name" => "Alice", "age" => 30, "status" => "active"},
    %{"name" => "Bob", "age" => 17, "status" => "active"},
    %{"name" => "Carol", "age" => 65, "status" => "inactive"}
  ]

  setup do
    %{conn: %{["users"] => @users}}
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
end
