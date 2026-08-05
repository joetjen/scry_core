defmodule ScryCore.ExecutorTest do
  use ExUnit.Case, async: true

  alias ScryCore.{Executor, Query, Rational}

  # A minimal fixture, not the real static engine (that's
  # scry_test_engine_core, a separate package -- scry_core can't
  # depend on it without a cycle, since it depends on scry_core).
  # `conn` here is just a %{source_path => rows} map.
  defmodule FakeEngine do
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
    %{"name" => "Bob", "age" => 17, "status" => "pending"},
    %{"name" => "Carol", "age" => 65, "status" => "inactive"}
  ]

  @orders [%{"id" => 1, "total" => 75}]

  @products [
    %{"name" => "Widget", "price" => 3},
    %{"name" => "Gadget", "price" => 4}
  ]

  @events [
    # Stored at 6-digit (default) microsecond precision -- deliberately
    # not matching whatever precision a query literal happens to parse
    # at, the exact mismatch that broke Kernel `==`/`<` for DateTime and
    # NaiveDateTime before ScryCore.Executor.compare/3 dispatched
    # through DateTime.compare/2/NaiveDateTime.compare/2 instead.
    %{"name" => "launch", "at" => ~U[2026-01-01 14:00:00.500000Z]},
    %{"name" => "standup", "at" => ~N[2026-01-01 09:00:00.500000]}
  ]

  @data %{
    ["users"] => @users,
    ["orders"] => @orders,
    ["products"] => @products,
    ["events"] => @events
  }

  defp run(query), do: Executor.run(query, FakeEngine, @data)

  test "no wheres, projects the selected fields" do
    query = %Query{source: ["users"], select: [{:field, ["name"]}]}

    assert {:ok, rows} = run(query)
    assert rows == [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Carol"}]
  end

  test "a comparison predicate filters rows" do
    query = %Query{
      source: ["users"],
      wheres: [{:cmp, :gt, ["age"], 18}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "and/or/not combine correctly" do
    and_query = %Query{
      source: ["users"],
      wheres: [{:and, {:cmp, :gt, ["age"], 18}, {:cmp, :lt, ["age"], 40}}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Alice"}]} = run(and_query)

    or_query = %Query{
      source: ["users"],
      wheres: [{:or, {:cmp, :lt, ["age"], 18}, {:cmp, :gt, ["age"], 60}}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Bob"}, %{"name" => "Carol"}]} = run(or_query)

    not_query = %Query{
      source: ["users"],
      wheres: [{:not, {:cmp, :eq, ["status"], "active"}}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Bob"}, %{"name" => "Carol"}]} = run(not_query)
  end

  test "in [...] membership" do
    query = %Query{
      source: ["users"],
      wheres: [{:in, ["status"], ["active", "pending"]}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Alice"}, %{"name" => "Bob"}]} = run(query)
  end

  test "wheres is a list combined with and, per Query's own moduledoc" do
    query = %Query{
      source: ["users"],
      wheres: [{:cmp, :gt, ["age"], 18}, {:cmp, :eq, ["status"], "active"}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Alice"}]} = run(query)
  end

  test "a nested SELECT runs independently, uncorrelated to the outer row" do
    query = %Query{
      source: ["users"],
      select: [
        {:field, ["name"]},
        %Query{source: ["orders"], select: [{:field, ["id"]}]}
      ]
    }

    assert {:ok, rows} = run(query)

    # Every outer row gets the identical nested result -- Phase 1's
    # grammar has no correlation syntax yet, see this module's own
    # moduledoc.
    assert rows == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 1}]},
             %{"name" => "Carol", "orders" => [%{"id" => 1}]}
           ]
  end

  test "a :variant body item has no execution semantics here, and errors explicitly" do
    query = %Query{source: ["users"], select: [{:variant, %{some: "kind-specific thing"}}]}

    assert {:error, {:unsupported_body_item, {:variant, _}}} = run(query)
  end

  test "an unknown source propagates the adapter's own error" do
    query = %Query{source: ["nonexistent"], select: []}

    assert {:error, {:no_such_source, ["nonexistent"]}} = run(query)
  end

  test "a %Rational{} literal compares exactly against a plain-integer row value" do
    query = %Query{
      source: ["products"],
      wheres: [{:cmp, :gt, ["price"], Rational.new(7, 2)}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Gadget"}]} = run(query)
  end

  test "a %Rational{} literal that reduces to an integer still compares correctly" do
    query = %Query{
      source: ["products"],
      wheres: [{:cmp, :eq, ["price"], Rational.new(8, 2)}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Gadget"}]} = run(query)
  end

  test "a %DateTime{} literal compares equal to a row value at a different microsecond precision" do
    query = %Query{
      source: ["events"],
      wheres: [{:cmp, :eq, ["at"], ~U[2026-01-01 14:00:00.5Z]}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "launch"}]} = run(query)
  end

  test "a %DateTime{} literal orders correctly despite a microsecond-precision mismatch" do
    query = %Query{
      source: ["events"],
      wheres: [{:cmp, :gt, ["at"], ~U[2026-01-01 13:59:59Z]}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "launch"}]} = run(query)

    not_after_query = %Query{
      source: ["events"],
      wheres: [{:cmp, :gt, ["at"], ~U[2026-01-01 14:00:00.500000Z]}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, []} = run(not_after_query)
  end

  test "a %NaiveDateTime{} literal compares equal despite a microsecond-precision mismatch" do
    query = %Query{
      source: ["events"],
      wheres: [{:cmp, :eq, ["at"], ~N[2026-01-01 09:00:00.5]}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "standup"}]} = run(query)
  end
end
