defmodule Scry.Core.ExecutorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Core.{CombinedQuery, Cursor, Executor, Query, Rational}
  alias Scry.Core.Executor.QueryError
  alias Scry.Core.Test.ReferenceEngine, as: FakeEngine
  alias Scry.Core.Test.RowReferenceEngine, as: RowEngine
  alias Scry.Core.Test.StreamingReferenceEngine, as: StreamEngine

  @users [
    %{"name" => "Alice", "age" => 30, "status" => "active"},
    %{"name" => "Bob", "age" => 17, "status" => "pending"},
    %{"name" => "Carol", "age" => 65, "status" => "inactive"}
  ]

  @orders [%{"id" => 1, "total" => 75}]

  @products [
    %{"name" => "Widget", "price" => 3, "cost" => 4},
    %{"name" => "Gadget", "price" => 4, "cost" => 2}
  ]

  @events [
    # Stored at 6-digit (default) microsecond precision -- deliberately
    # not matching whatever precision a query literal happens to parse
    # at, the exact mismatch that broke Kernel `==`/`<` for DateTime and
    # NaiveDateTime before Scry.Core.Executor.compare/3 dispatched
    # through DateTime.compare/2/NaiveDateTime.compare/2 instead.
    %{"name" => "launch", "at" => ~U[2026-01-01 14:00:00.500000Z]},
    %{"name" => "standup", "at" => ~N[2026-01-01 09:00:00.500000]}
  ]

  # For rate(<duration>): svc-a's 4 rows span exactly 120s, svc-b's 3
  # rows span exactly 60s -- both hand-computable (rate(30s): svc-a is
  # 4*30/120 = 1, svc-b is 3*30/60 = 1.5), and different enough from
  # each other that a GROUP BY test can't pass by accident.
  @rate_events [
    %{"service" => "svc-a", "at" => ~U[2026-01-01 00:00:00.000000Z]},
    %{"service" => "svc-a", "at" => ~U[2026-01-01 00:00:40.000000Z]},
    %{"service" => "svc-a", "at" => ~U[2026-01-01 00:01:20.000000Z]},
    %{"service" => "svc-a", "at" => ~U[2026-01-01 00:02:00.000000Z]},
    %{"service" => "svc-b", "at" => ~U[2026-01-01 00:00:00.000000Z]},
    %{"service" => "svc-b", "at" => ~U[2026-01-01 00:00:30.000000Z]},
    %{"service" => "svc-b", "at" => ~U[2026-01-01 00:01:00.000000Z]}
  ]

  # A NaiveDateTime-timestamped sibling, to exercise elapsed_seconds/2's
  # other clause -- 3 rows spanning exactly 60s (rate(30s) = 1.5, same
  # arithmetic as svc-b above).
  @rate_events_naive [
    %{"service" => "svc-c", "at" => ~N[2026-01-01 00:00:00.000000]},
    %{"service" => "svc-c", "at" => ~N[2026-01-01 00:00:30.000000]},
    %{"service" => "svc-c", "at" => ~N[2026-01-01 00:01:00.000000]}
  ]

  # Fetch order (A, B, C, D) deliberately doesn't match sort order by
  # either field -- lets a stability/tie-breaking test tell a real sort
  # apart from an accidental one.
  @accounts [
    %{"name" => "A", "tier" => "gold", "score" => 3},
    %{"name" => "B", "tier" => "silver", "score" => 1},
    %{"name" => "C", "tier" => "gold", "score" => 2},
    %{"name" => "D", "tier" => "silver", "score" => 4}
  ]

  # For correlation/REQUIRED: Bob has no matching orders at all (tests
  # REQUIRED dropping an outer row); Alice and Carol both do (tests
  # limit-after-drop counts survivors, not raw sorted rows).
  @customers [
    %{"id" => 1, "name" => "Alice"},
    %{"id" => 2, "name" => "Bob"},
    %{"id" => 3, "name" => "Carol"}
  ]

  @customer_orders [
    %{"id" => 100, "customer_id" => 1, "total" => 50},
    %{"id" => 101, "customer_id" => 1, "total" => 75},
    %{"id" => 102, "customer_id" => 3, "total" => 20}
  ]

  # `customer_id` here deliberately correlates to the *grandparent*
  # (customers), not the immediate parent (customer_orders) -- proves
  # the scope chain reaches more than one level up, not just the
  # nearest enclosing query.
  @order_items [
    %{"id" => 1000, "order_id" => 100, "customer_id" => 1, "sku" => "A"},
    %{"id" => 1001, "order_id" => 101, "customer_id" => 1, "sku" => "B"},
    %{"id" => 1002, "order_id" => 102, "customer_id" => 3, "sku" => "C"}
  ]

  @line_items [
    %{"price" => 3, "quantity" => 4},
    %{"price" => Rational.new(3, 2), "quantity" => 2}
  ]

  # For UNION/INTERSECT/EXCEPT: Alice appears twice in team_a (tests
  # dedup collapsing an in-source duplicate, not just a cross-source
  # one); Bob is the one name in both teams (INTERSECT's own "in both"
  # case); Carol is team_b-only (proves EXCEPT keeps only team_a's own
  # rows, not anything from the right side).
  @team_a [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Alice"}]
  @team_b [%{"name" => "Bob"}, %{"name" => "Carol"}]

  # For json(<field>): metadata is an ordinary String field, not
  # declared as any kind of Json type -- exactly the "escape hatch"
  # case lang_spec.md §7 describes.
  @tickets [
    %{"id" => 1, "metadata" => ~s({"color":"red","tags":["urgent","new"]})},
    %{"id" => 2, "metadata" => ~s({"color":"blue","tags":["sale"]})}
  ]

  # For `in`-with-a-computed-list: `metadata` is a genuine nested map
  # here (unlike @tickets' own JSON-encoded *string*), the direct
  # lang_spec.md §7 shape -- `metadata.tags` is already a list-valued
  # subfield, no `json()` unwrapping needed. Card 2 has no "urgent" tag
  # at all (tests the negative case); card 3's own `tags` is an empty
  # list (tests membership against a genuinely empty computed list,
  # not just a non-matching one).
  @cards [
    %{"id" => 1, "metadata" => %{"tags" => ["urgent", "new"]}},
    %{"id" => 2, "metadata" => %{"tags" => ["sale"]}},
    %{"id" => 3, "metadata" => %{"tags" => []}}
  ]

  # A well-known textbook example (mean 5, population variance 4,
  # population stddev 2) -- lets a test assert exact, hand-checkable
  # numbers rather than an opaque "close to" float comparison.
  @measurements [
    %{"id" => 1, "v" => 2},
    %{"id" => 2, "v" => 4},
    %{"id" => 3, "v" => 4},
    %{"id" => 4, "v" => 4},
    %{"id" => 5, "v" => 5},
    %{"id" => 6, "v" => 5},
    %{"id" => 7, "v" => 7},
    %{"id" => 8, "v" => 9}
  ]

  # For window functions -- lang_spec.md §11's own worked example shape
  # (`department`/`salary`). Bob and Carol are deliberately tied at the
  # same salary within "eng" (tests `rank()`'s own tie-awareness against
  # `row_number()`'s own strict sequence); Bob appears *before* Carol in
  # fetch order despite the tie (tests that a stable sort, not fetch
  # order, decides who's "first" among ties once `ORDER BY` picks a
  # direction).
  @employees [
    %{"name" => "Alice", "department" => "eng", "salary" => 100},
    %{"name" => "Bob", "department" => "eng", "salary" => 120},
    %{"name" => "Carol", "department" => "eng", "salary" => 120},
    %{"name" => "Dave", "department" => "sales", "salary" => 90},
    %{"name" => "Eve", "department" => "sales", "salary" => 110}
  ]

  # lang_spec.md §5.2's own ROLLUP/CUBE vocabulary (region/quarter). Two
  # regions x two quarters, every combination present, so a subtotal at
  # any level always has more than one member row to sum -- a single-
  # member subtotal wouldn't tell "the aggregate really spans the
  # rolled-up members" apart from "it just copied the one row's value."
  @sales [
    %{"region" => "east", "quarter" => "q1", "amount" => 100},
    %{"region" => "east", "quarter" => "q2", "amount" => 150},
    %{"region" => "west", "quarter" => "q1", "amount" => 200},
    %{"region" => "west", "quarter" => "q2", "amount" => 50}
  ]

  @data %{
    ["users"] => @users,
    ["orders"] => @orders,
    ["products"] => @products,
    ["events"] => @events,
    ["accounts"] => @accounts,
    ["customers"] => @customers,
    ["customer_orders"] => @customer_orders,
    ["order_items"] => @order_items,
    ["line_items"] => @line_items,
    ["team_a"] => @team_a,
    ["team_b"] => @team_b,
    ["tickets"] => @tickets,
    ["cards"] => @cards,
    ["measurements"] => @measurements,
    ["employees"] => @employees,
    ["sales"] => @sales,
    ["rate_events"] => @rate_events,
    ["rate_events_naive"] => @rate_events_naive
  }

  # `Executor.run/3,4` returns `{:ok, Cursor.t()}` now, not `{:ok, [row()]}`
  # (`Scry.Core.Cursor`'s own moduledoc has the full reasoning) --
  # `materialize/1` drains it back to this suite's own long-established
  # `{:ok, [row()]} | {:error, reason}` shape, converting a lazily-raised
  # `QueryError` (a failure only discoverable mid-pull -- an unsupported
  # body item, today's only case) back into the classic tuple, so every
  # existing test calling `run/1,2`/`run_via_stream/1` below needs zero
  # changes of its own.
  defp run(query), do: query |> Executor.run(FakeEngine, @data) |> materialize()
  defp run(query, params), do: query |> Executor.run(FakeEngine, @data, params) |> materialize()
  defp run_via_stream(query), do: query |> Executor.run(StreamEngine, @data) |> materialize()
  defp run_via_row_engine(query), do: query |> Executor.run(RowEngine, @data) |> materialize()

  defp materialize({:error, _} = err), do: err

  defp materialize({:ok, cursor}) do
    {:ok, Cursor.to_list(cursor)}
  rescue
    e in QueryError -> {:error, e.reason}
  end

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

  test "an unresolved {:variant, ...} predicate (EP1(e), e.g. SEARCH) hard-errors with a clear message, ungrouped path" do
    query = %Query{
      source: ["users"],
      wheres: [{:variant, {:search, ["name"], "alice"}}],
      select: [{:field, ["name"]}]
    }

    assert_raise ArgumentError, ~r/unresolved.*variant.*predicate.*fully lower/s, fn ->
      run(query)
    end
  end

  test "an unresolved {:variant, ...} predicate also hard-errors nested inside AND/OR" do
    query = %Query{
      source: ["users"],
      wheres: [{:and, {:cmp, :eq, ["status"], "active"}, {:variant, {:search, ["name"], "a"}}}],
      select: [{:field, ["name"]}]
    }

    assert_raise ArgumentError, ~r/unresolved.*variant.*predicate/s, fn -> run(query) end
  end

  test "an unresolved {:variant, ...} predicate hard-errors in HAVING too, grouped path" do
    query = %Query{
      source: ["customer_orders"],
      group_bys: [["customer_id"]],
      havings: [{:variant, {:search, ["id"], "1"}}],
      select: [{:field, ["customer_id"]}]
    }

    assert_raise ArgumentError, ~r/unresolved.*variant.*predicate/s, fn -> run(query) end
  end

  test "an unresolved {:variant, ...} predicate in HAVING also hard-errors with no GROUP BY at all (the flat-aggregate path, aggregate_query?'s own group_bys-empty branch)" do
    query = %Query{
      source: ["customer_orders"],
      havings: [{:variant, {:search, ["id"], "1"}}],
      select: [{:computed, "total", {:call, "sum", [{:field, ["total"]}]}}]
    }

    assert_raise ArgumentError, ~r/unresolved.*variant.*predicate/s, fn -> run(query) end
  end

  test "an unknown source propagates the adapter's own error" do
    query = %Query{source: ["nonexistent"], select: []}

    assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} = run(query)
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

  test "order_by, ascending and descending" do
    asc = %Query{
      source: ["accounts"],
      order_bys: [{["score"], :asc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(asc)
    assert Enum.map(rows, & &1["name"]) == ["B", "C", "A", "D"]

    desc = %Query{
      source: ["accounts"],
      order_bys: [{["score"], :desc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(desc)
    assert Enum.map(rows, & &1["name"]) == ["D", "A", "C", "B"]
  end

  test "order_by is a stable sort -- ties preserve original fetch order" do
    query = %Query{
      source: ["accounts"],
      order_bys: [{["tier"], :asc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    # gold (A, C) before silver (B, D) alphabetically by tier, and within
    # each tier the original A/B/C/D fetch order survives untouched.
    assert Enum.map(rows, & &1["name"]) == ["A", "C", "B", "D"]
  end

  test "order_by with a secondary key breaks ties from the first" do
    query = %Query{
      source: ["accounts"],
      order_bys: [{["tier"], :asc}, {["score"], :desc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["A", "C", "D", "B"]
  end

  test "order_by evaluates against the source row, not the projected shape" do
    # "score" is nowhere in `select` -- only resolvable at all if
    # sorting happens before projection, against the source row.
    query = %Query{
      source: ["accounts"],
      order_bys: [{["score"], :asc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["B", "C", "A", "D"]
  end

  test "order_by's own key can be a full expr(), not just a bare field -- an arithmetic key" do
    # Widget: 3 * 4 = 12, Gadget: 4 * 2 = 8 -- Widget sorts first descending.
    query = %Query{
      source: ["products"],
      order_bys: [{{:arith, :mul, {:field, ["price"]}, {:field, ["cost"]}}, :desc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["Widget", "Gadget"]
  end

  test "order_by's own key still accepts the explicit {:field, path} tag, not just a bare list" do
    query = %Query{
      source: ["accounts"],
      order_bys: [{{:field, ["score"]}, :asc}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["B", "C", "A", "D"]
  end

  test "distinct dedupes the projected shape, keeping the first occurrence" do
    query = %Query{source: ["accounts"], distinct: true, select: [{:field, ["tier"]}]}

    assert {:ok, rows} = run(query)
    assert rows == [%{"tier" => "gold"}, %{"tier" => "silver"}]
  end

  test "distinct dedupes after order_by, so sort order decides which duplicate survives" do
    query = %Query{
      source: ["accounts"],
      order_bys: [{["score"], :desc}],
      distinct: true,
      select: [{:field, ["tier"]}]
    }

    # Sorted desc by score first: D(4,silver), A(3,gold), C(2,gold), B(1,silver)
    # -- then deduped on the projected {"tier" => _} shape, keeping each
    # tier's first appearance in *that* order: silver (from D) before gold
    # (from A).
    assert {:ok, rows} = run(query)
    assert rows == [%{"tier" => "silver"}, %{"tier" => "gold"}]
  end

  test "limit alone" do
    query = %Query{source: ["accounts"], limit: 2, select: [{:field, ["name"]}]}
    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["A", "B"]
  end

  test "limit with offset" do
    query = %Query{source: ["accounts"], limit: 2, offset: 1, select: [{:field, ["name"]}]}
    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["B", "C"]
  end

  test "an offset past the end of the result set yields no rows" do
    query = %Query{source: ["accounts"], offset: 10, select: [{:field, ["name"]}]}
    assert {:ok, []} = run(query)
  end

  test "limit, order_by, and distinct compose together" do
    query = %Query{
      source: ["accounts"],
      order_bys: [{["score"], :asc}],
      limit: 2,
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query)
    assert Enum.map(rows, & &1["name"]) == ["B", "C"]
  end

  test "a regex sigil literal matches via ~" do
    query = %Query{
      source: ["users"],
      wheres: [{:cmp, :match, ["name"], ~r/^A/}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, [%{"name" => "Alice"}]} = run(query)
  end

  test "~ with no match yields no rows" do
    query = %Query{
      source: ["users"],
      wheres: [{:cmp, :match, ["name"], ~r/^Z/}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, []} = run(query)
  end

  test "a field-to-field comparison filters by comparing two fields of the same row" do
    query = %Query{
      source: ["products"],
      wheres: [{:cmp, :gt, ["price"], {:field, ["cost"]}}],
      select: [{:field, ["name"]}]
    }

    # Widget: price 3, cost 4 (not >) -- Gadget: price 4, cost 2 (>)
    assert {:ok, [%{"name" => "Gadget"}]} = run(query)
  end

  test "~ against a right-hand side that resolves to a non-regex raises" do
    query = %Query{
      source: ["products"],
      wheres: [{:cmp, :match, ["name"], {:field, ["cost"]}}],
      select: [{:field, ["name"]}]
    }

    assert_raise FunctionClauseError, fn -> run(query) end
  end

  defp orders_for(customer_id_path) do
    %Query{
      source: ["customer_orders"],
      wheres: [{:cmp, :eq, ["customer_id"], {:field, customer_id_path}}],
      select: [{:field, ["id"]}]
    }
  end

  test "a correlated nested SELECT produces a different result per outer row" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [{:field, ["name"]}, orders_for(["customers", "id"])]
    }

    assert {:ok, rows} = run(query)

    assert rows == [
             %{
               "name" => "Alice",
               "customer_orders" => [%{"id" => 100}, %{"id" => 101}]
             },
             %{"name" => "Bob", "customer_orders" => []},
             %{"name" => "Carol", "customer_orders" => [%{"id" => 102}]}
           ]
  end

  test "a correlated nested SELECT produces the identical result when the outer (shell) query's own rows are Scry.Core.Row values, not plain maps" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [{:field, ["name"]}, orders_for(["customers", "id"])]
    }

    assert run_via_row_engine(query) == run(query)
  end

  test "REQUIRED drops an outer row whose correlated nested query is empty" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [{:field, ["name"]}, %{orders_for(["customers", "id"]) | required: true}]
    }

    assert {:ok, rows} = run(query)

    assert rows == [
             %{
               "name" => "Alice",
               "customer_orders" => [%{"id" => 100}, %{"id" => 101}]
             },
             %{"name" => "Carol", "customer_orders" => [%{"id" => 102}]}
           ]
  end

  test "limit applies after REQUIRED drops rows, not before" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["name"], :asc}],
      limit: 2,
      select: [{:field, ["name"]}, %{orders_for(["customers", "id"]) | required: true}]
    }

    assert {:ok, rows} = run(query)

    # Sorted ascending by name: Alice, Bob, Carol -- if limit ran before
    # the REQUIRED drop, "top 2" would be [Alice, Bob], and dropping
    # Bob afterward would leave only 1 row despite limit: 2. It doesn't:
    # Bob is dropped first, so the surviving two (Alice, Carol) both
    # make it through limit: 2.
    assert Enum.map(rows, & &1["name"]) == ["Alice", "Carol"]
  end

  test "correlation reaching more than one nesting level up (grandparent) is a documented gap, not silently wrong" do
    # `Scry.Core.QueryOps.run_document/4`'s own moduledoc documents
    # this as a deliberate, narrower scope than the pre-pivot
    # interpreter it replaces: a nested query's own correlated
    # reference must name its *immediate* enclosing query. `grandchild`
    # here names "customers" -- its own grandparent, not its immediate
    # parent ("customer_orders") -- so the reference is never rewritten
    # into a resolvable `{:param, ...}` binding, is left as a literal,
    # unresolvable 2-segment field path, resolves to `nil` against
    # `order_items`'s own rows, and hits the ordinary null-safety hard
    # error every unresolvable comparison already gets -- a real,
    # honest failure, not a silently wrong answer.
    grandchild = %Query{
      source: ["order_items"],
      wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
      select: [{:field, ["sku"]}]
    }

    order_with_items = %Query{
      source: ["customer_orders"],
      wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
      select: [{:field, ["id"]}, grandchild]
    }

    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [{:field, ["name"]}, order_with_items]
    }

    assert_raise ArgumentError, ~r/null-safety/, fn -> run(query) end
  end

  test "an external parameter is resolved against the params map at execution time" do
    query = %Query{
      source: ["users"],
      wheres: [{:cmp, :gt, ["age"], {:param, "minAge"}}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query, %{"minAge" => 18})
    assert Enum.map(rows, & &1["name"]) == ["Alice", "Carol"]

    assert {:ok, rows2} = run(query, %{"minAge" => 60})
    assert Enum.map(rows2, & &1["name"]) == ["Carol"]
  end

  test "an external parameter inside an in [...] list" do
    query = %Query{
      source: ["users"],
      wheres: [{:in, ["status"], [{:param, "a"}, "inactive"]}],
      select: [{:field, ["name"]}]
    }

    assert {:ok, rows} = run(query, %{"a" => "active"})
    assert Enum.map(rows, & &1["name"]) == ["Alice", "Carol"]
  end

  test "a query referencing an external parameter with no value supplied raises" do
    query = %Query{
      source: ["users"],
      wheres: [{:cmp, :gt, ["age"], {:param, "minAge"}}],
      select: [{:field, ["name"]}]
    }

    assert_raise ArgumentError, ~r/minAge/, fn -> run(query) end
  end

  test "an external parameter reaches a nested SELECT's own WHERE too" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [
        {:field, ["name"]},
        %Query{
          source: ["customer_orders"],
          wheres: [
            {:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}},
            {:cmp, :gt, ["total"], {:param, "minTotal"}}
          ],
          select: [{:field, ["id"]}]
        }
      ]
    }

    assert {:ok, rows} = run(query, %{"minTotal" => 60})

    assert rows == [
             %{"name" => "Alice", "customer_orders" => [%{"id" => 101}]},
             %{"name" => "Bob", "customer_orders" => []},
             %{"name" => "Carol", "customer_orders" => []}
           ]
  end

  test "a conditionally-included field is present when its param is truthy" do
    query = %Query{
      source: ["users"],
      select: [{:field, ["name"]}, {:field, ["age"], {:param, "includeAge"}}]
    }

    assert {:ok, rows} = run(query, %{"includeAge" => true})

    assert rows == [
             %{"name" => "Alice", "age" => 30},
             %{"name" => "Bob", "age" => 17},
             %{"name" => "Carol", "age" => 65}
           ]
  end

  test "a conditionally-included field's key is entirely absent when its param is falsy" do
    query = %Query{
      source: ["users"],
      select: [{:field, ["name"]}, {:field, ["age"], {:param, "includeAge"}}]
    }

    assert {:ok, rows} = run(query, %{"includeAge" => false})
    assert rows == [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Carol"}]
    refute Map.has_key?(hd(rows), "age")
  end

  test "nil is also falsy for a conditionally-included field, same as false" do
    query = %Query{
      source: ["users"],
      select: [{:field, ["name"]}, {:field, ["age"], {:param, "includeAge"}}]
    }

    assert {:ok, [%{"name" => "Alice"} = row | _]} = run(query, %{"includeAge" => nil})
    refute Map.has_key?(row, "age")
  end

  test "a missing param for a conditionally-included field still raises" do
    query = %Query{
      source: ["users"],
      select: [{:field, ["name"]}, {:field, ["age"], {:param, "includeAge"}}]
    }

    assert_raise ArgumentError, ~r/includeAge/, fn -> run(query) end
  end

  test "a computed field: price * quantity, integer result" do
    query = %Query{
      source: ["line_items"],
      select: [
        {:computed, "subtotal", {:arith, :mul, {:field, ["price"]}, {:field, ["quantity"]}}}
      ]
    }

    assert {:ok, [%{"subtotal" => 12}, %{"subtotal" => 3}]} = run(query)
  end

  test "a computed field stays exact when the result isn't a whole number" do
    query = %Query{
      source: ["line_items"],
      select: [{:computed, "half_price", {:arith, :div, {:field, ["price"]}, 2}}]
    }

    assert {:ok, [%{"half_price" => half1}, %{"half_price" => half2}]} = run(query)
    assert half1 == Rational.new(3, 2)
    assert half2 == Rational.new(3, 4)
  end

  test "a computed field can reference an external parameter" do
    query = %Query{
      source: ["line_items"],
      select: [
        {:computed, "discounted", {:arith, :sub, {:field, ["price"]}, {:param, "discount"}}}
      ]
    }

    assert {:ok, [%{"discounted" => 1}, %{"discounted" => discounted2}]} =
             run(query, %{"discount" => 2})

    assert discounted2 == Rational.new(-1, 2)
  end

  test "a computed field composes with correlation, reaching an enclosing row" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [
        {:field, ["name"]},
        %Query{
          source: ["customer_orders"],
          wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
          select: [{:computed, "with_tax", {:arith, :mul, {:field, ["total"]}, {:param, "rate"}}}]
        }
      ]
    }

    assert {:ok, rows} = run(query, %{"rate" => Rational.new(11, 10)})

    assert [
             %{"name" => "Alice", "customer_orders" => alice_orders},
             %{"name" => "Bob", "customer_orders" => []},
             %{"name" => "Carol", "customer_orders" => carol_orders}
           ] = rows

    assert alice_orders == [
             %{"with_tax" => Rational.new(55, 1)},
             %{"with_tax" => Rational.new(165, 2)}
           ]

    assert carol_orders == [%{"with_tax" => Rational.new(22, 1)}]
  end

  test "division by zero in a computed field raises, same as the literal path" do
    query = %Query{
      source: ["line_items"],
      select: [{:computed, "bad", {:arith, :div, {:field, ["price"]}, 0}}]
    }

    assert_raise ArithmeticError, fn -> run(query) end
  end

  test "a non-integer exponent in a computed field raises a clear error" do
    query = %Query{
      source: ["line_items"],
      select: [{:computed, "bad", {:arith, :pow, 2, Rational.new(1, 2)}}]
    }

    assert_raise ArgumentError, ~r/exponent must be an integer/, fn -> run(query) end
  end

  test "WHEN/THEN/ELSE evaluates clauses in order, first match wins" do
    query = %Query{
      source: ["users"],
      order_bys: [{["age"], :asc}],
      select: [
        {:field, ["name"]},
        {:computed, "tier",
         {:when,
          [
            {{:cmp, :gt, ["age"], 60}, "senior"},
            {{:cmp, :gt, ["age"], 18}, "adult"}
          ], "minor"}}
      ]
    }

    assert {:ok, rows} = run(query)

    assert rows == [
             %{"name" => "Bob", "tier" => "minor"},
             %{"name" => "Alice", "tier" => "adult"},
             %{"name" => "Carol", "tier" => "senior"}
           ]
  end

  test "WHEN/THEN/ELSE falls through to ELSE when nothing matches" do
    query = %Query{
      source: ["users"],
      select: [{:computed, "flag", {:when, [{{:cmp, :eq, ["status"], "banned"}, "x"}], "ok"}}]
    }

    assert {:ok, rows} = run(query)
    assert Enum.all?(rows, &(&1["flag"] == "ok"))
  end

  test "a WHEN condition can reference an external parameter" do
    query = %Query{
      source: ["users"],
      select: [
        {:field, ["name"]},
        {:computed, "flag", {:when, [{{:cmp, :gt, ["age"], {:param, "cutoff"}}, "old"}], "young"}}
      ]
    }

    assert {:ok, rows} = run(query, %{"cutoff" => 20})
    assert Enum.find(rows, &(&1["name"] == "Bob"))["flag"] == "young"
    assert Enum.find(rows, &(&1["name"] == "Alice"))["flag"] == "old"
  end

  test "WHEN/THEN/ELSE composes with correlation inside a nested SELECT" do
    query = %Query{
      source: ["customers"],
      order_bys: [{["id"], :asc}],
      select: [
        {:field, ["name"]},
        %Query{
          source: ["customer_orders"],
          wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
          select: [
            {:computed, "size", {:when, [{{:cmp, :gt, ["total"], 60}, "big"}], "small"}}
          ]
        }
      ]
    }

    assert {:ok, rows} = run(query)

    assert rows == [
             %{
               "name" => "Alice",
               "customer_orders" => [%{"size" => "small"}, %{"size" => "big"}]
             },
             %{"name" => "Bob", "customer_orders" => []},
             %{"name" => "Carol", "customer_orders" => [%{"size" => "small"}]}
           ]
  end

  describe "GROUP BY / HAVING / aggregate functions" do
    # @customer_orders: customer_id 1 has two orders (50, 75 -- total
    # 125), customer_id 3 has one (20). No `GROUP BY` collapses every
    # matched row into one implicit group -- the same mechanism, not a
    # special case (Scry.Core.Executor's own moduledoc).
    test "a flat aggregate (no GROUP BY) collapses every row into one output row" do
      query = %Query{
        source: ["customer_orders"],
        select: [
          {:computed, "order_count", {:call, "count", [{:field, ["id"]}]}},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}},
          {:computed, "avg", {:call, "avg", [{:field, ["total"]}]}},
          {:computed, "lo", {:call, "min", [{:field, ["total"]}]}},
          {:computed, "hi", {:call, "max", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, [row]} = run(query)

      assert row == %{
               "order_count" => 3,
               "total" => 145,
               "avg" => Rational.new(145, 3),
               "lo" => 20,
               "hi" => 75
             }
    end

    test "GROUP BY produces one row per distinct key" do
      query = %Query{
        source: ["customer_orders"],
        group_bys: [["customer_id"]],
        order_bys: [{["customer_id"], :asc}],
        select: [
          {:field, ["customer_id"]},
          {:computed, "order_count", {:call, "count", [{:field, ["id"]}]}},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"customer_id" => 1, "order_count" => 2, "total" => 125},
               %{"customer_id" => 3, "order_count" => 1, "total" => 20}
             ]
    end

    test "HAVING drops groups that don't satisfy the aggregate predicate" do
      query = %Query{
        source: ["customer_orders"],
        group_bys: [["customer_id"]],
        havings: [{:cmp, :gt, {:call, "sum", [{:field, ["total"]}]}, 100}],
        select: [
          {:field, ["customer_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert rows == [%{"customer_id" => 1, "total" => 125}]
    end

    test "a zero-row flat aggregate is still one well-defined output row" do
      query = %Query{
        source: ["customer_orders"],
        wheres: [{:cmp, :eq, ["customer_id"], 999}],
        select: [
          {:computed, "c", {:call, "count", [{:field, ["id"]}]}},
          {:computed, "s", {:call, "sum", [{:field, ["total"]}]}},
          {:computed, "a", {:call, "avg", [{:field, ["total"]}]}},
          {:computed, "lo", {:call, "min", [{:field, ["total"]}]}},
          {:computed, "hi", {:call, "max", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, [row]} = run(query)
      assert row == %{"c" => 0, "s" => nil, "a" => nil, "lo" => nil, "hi" => nil}
    end

    test "ORDER BY/LIMIT compose with GROUP BY, applied to the projected group rows" do
      query = %Query{
        source: ["customer_orders"],
        group_bys: [["customer_id"]],
        order_bys: [{["total"], :desc}],
        limit: 1,
        select: [
          {:field, ["customer_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert rows == [%{"customer_id" => 1, "total" => 125}]
    end

    test "an aggregate over a field that's nil on every row hard-errors, no silent skip" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "x", {:call, "sum", [{:field, ["discount"]}]}}]
      }

      assert_raise ArgumentError, ~r/encountered a nil value/, fn -> run(query) end
    end

    test "an unknown/unsupported function name raises a clear error" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "x", {:call, "foo", [{:field, ["id"]}]}}]
      }

      assert_raise ArgumentError, ~r/unknown or unsupported function/, fn -> run(query) end
    end

    test "a known aggregate called with the wrong number of arguments raises" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "x", {:call, "sum", [{:field, ["id"]}, {:field, ["total"]}]}}]
      }

      assert_raise ArgumentError, ~r/expects exactly one argument/, fn -> run(query) end
    end

    test "a call used as an ordinary per-row predicate's left-hand side raises a clear error" do
      query = %Query{
        source: ["customer_orders"],
        wheres: [{:cmp, :gt, {:call, "sum", [{:field, ["total"]}]}, 1}],
        select: [{:field, ["id"]}]
      }

      assert_raise ArgumentError, ~r/only valid inside GROUP BY\/HAVING/, fn -> run(query) end
    end

    test "a nested, un-grouped SELECT with aggregate fields is a flat aggregate per outer row (lang_spec §11)" do
      query = %Query{
        source: ["customers"],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: ["customer_orders"],
            wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
            select: [
              {:computed, "order_count", {:call, "count", [{:field, ["id"]}]}},
              {:computed, "total_spent", {:call, "sum", [{:field, ["total"]}]}}
            ]
          }
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{
                 "name" => "Alice",
                 "customer_orders" => [%{"order_count" => 2, "total_spent" => 125}]
               },
               %{
                 "name" => "Bob",
                 "customer_orders" => [%{"order_count" => 0, "total_spent" => nil}]
               },
               %{
                 "name" => "Carol",
                 "customer_orders" => [%{"order_count" => 1, "total_spent" => 20}]
               }
             ]
    end

    test "a nested SELECT inside a grouped query's own select now composes correctly (capability gained by the execute/3 pivot)" do
      # Previously a clear, deliberate error (`{:unsupported_grouped_
      # body_item, ...}`) -- the old per-row interpreter's own grouped
      # projection code had no way to run a nested query per group.
      # `Scry.Core.QueryOps.run_document/4` extracts a nested `SELECT`
      # from `select` before ever handing the "shell" query (here,
      # `GROUP BY customer_id { customer_id }`) to `QueryOps.run_flat/3`
      # or a real engine -- grouped or not is irrelevant to that
      # extraction, so this combination just works now, uncorrelated
      # nested items included.
      query = %Query{
        source: ["customer_orders"],
        group_bys: [["customer_id"]],
        select: [
          {:field, ["customer_id"]},
          %Query{source: ["order_items"], select: [{:field, ["sku"]}]}
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{
                 "customer_id" => 1,
                 "order_items" => [%{"sku" => "A"}, %{"sku" => "B"}, %{"sku" => "C"}]
               },
               %{
                 "customer_id" => 3,
                 "order_items" => [%{"sku" => "A"}, %{"sku" => "B"}, %{"sku" => "C"}]
               }
             ]
    end
  end

  describe "null-safety (lang_spec.md §7)" do
    @nullable_users [
      %{"name" => "Alice", "age" => 30},
      %{"name" => "Bob", "age" => nil},
      %{"name" => "Carol", "age" => 65}
    ]

    @nullable_orders [%{"status" => "open", "priority" => nil, "total" => 10}]

    test "comparing a nullable field directly against a typed value hard-errors when it's actually nil" do
      query = %Query{
        source: ["nullable_users"],
        wheres: [{:cmp, :gt, ["age"], 20}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} =
               Executor.run(query, FakeEngine, %{["nullable_users"] => @nullable_users})

      assert_raise ArgumentError, ~r/comparing a nullable field.*hard error/s, fn ->
        Cursor.to_list(cursor)
      end
    end

    test "field = nil is the explicit null-check idiom -- never hard-errors" do
      query = %Query{
        source: ["nullable_users"],
        wheres: [{:cmp, :eq, ["age"], nil}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} =
               run_against(query, %{["nullable_users"] => @nullable_users})

      assert rows == [%{"name" => "Bob"}]
    end

    test "field != nil is the explicit non-null check -- never hard-errors, even for the non-nil rows it excludes nothing about" do
      query = %Query{
        source: ["nullable_users"],
        wheres: [{:cmp, :not_eq, ["age"], nil}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} =
               run_against(query, %{["nullable_users"] => @nullable_users})

      assert Enum.sort(rows) == Enum.sort([%{"name" => "Alice"}, %{"name" => "Carol"}])
    end

    test "AND-guarded flow-sensitive narrowing avoids the hard error -- lang_spec.md's own worked example" do
      query = %Query{
        source: ["nullable_users"],
        wheres: [
          {:and, {:not, {:cmp, :eq, ["age"], nil}}, {:cmp, :gt, ["age"], 20}}
        ],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} =
               run_against(query, %{["nullable_users"] => @nullable_users})

      assert Enum.sort(rows) == Enum.sort([%{"name" => "Alice"}, %{"name" => "Carol"}])
    end

    test "OR short-circuit avoids the hard error -- lang_spec.md's own worked example" do
      query = %Query{
        source: ["nullable_users"],
        wheres: [{:or, {:cmp, :eq, ["age"], nil}, {:cmp, :gt, ["age"], 20}}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} =
               run_against(query, %{["nullable_users"] => @nullable_users})

      assert Enum.sort(rows) ==
               Enum.sort([%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Carol"}])
    end

    test "a WHEN clause's own guard predicate hard-errors the same way, reusing eval_predicate/4 directly" do
      query = %Query{
        source: ["nullable_users"],
        select: [
          {:computed, "bucket", {:when, [{{:cmp, :gt, ["age"], 20}, "adult"}], "unknown"}}
        ]
      }

      assert {:ok, cursor} =
               Executor.run(query, FakeEngine, %{["nullable_users"] => @nullable_users})

      assert_raise ArgumentError, ~r/comparing a nullable field.*hard error/s, fn ->
        Cursor.to_list(cursor)
      end
    end

    test "HAVING a bare grouped field unguarded hard-errors too, via the eager path (percentile forces :not_streamable)" do
      query = %Query{
        source: ["nullable_orders"],
        group_bys: [["status"]],
        havings: [{:cmp, :gt, ["priority"], 3}],
        select: [
          {:field, ["status"]},
          {:computed, "p", {:call, "percentile", [{:field, ["total"]}, 0.5]}}
        ]
      }

      assert_raise ArgumentError, ~r/comparing a nullable field.*hard error/s, fn ->
        run_against(query, %{["nullable_orders"] => @nullable_orders})
      end
    end

    test "HAVING a bare grouped field unguarded hard-errors too, via the streaming path" do
      query = %Query{
        source: ["nullable_orders"],
        group_bys: [["status"]],
        havings: [{:cmp, :gt, ["priority"], 3}],
        select: [{:field, ["status"]}]
      }

      assert_raise ArgumentError, ~r/comparing a nullable field.*hard error/s, fn ->
        run_against(query, %{["nullable_orders"] => @nullable_orders})
      end
    end

    test "HAVING priority = nil is the explicit null-check idiom in a grouped context too -- never hard-errors" do
      query = %Query{
        source: ["nullable_orders"],
        group_bys: [["status"]],
        havings: [{:cmp, :eq, ["priority"], nil}],
        select: [{:field, ["status"]}]
      }

      assert {:ok, rows} = run_against(query, %{["nullable_orders"] => @nullable_orders})
      assert rows == [%{"status" => "open"}]
    end

    test "HAVING an AND-guarded grouped field avoids the hard error, streaming path included" do
      query = %Query{
        source: ["nullable_orders"],
        group_bys: [["status"]],
        havings: [
          {:and, {:not, {:cmp, :eq, ["priority"], nil}}, {:cmp, :gt, ["priority"], 3}}
        ],
        select: [{:field, ["status"]}]
      }

      assert {:ok, rows} = run_against(query, %{["nullable_orders"] => @nullable_orders})
      assert rows == []
    end

    defp run_against(query, conn) do
      case Executor.run(query, FakeEngine, conn) do
        {:ok, cursor} -> {:ok, Cursor.to_list(cursor)}
        {:error, _} = err -> err
      end
    end
  end

  describe "bounded top-K streaming (a real ORDER BY combined with a real LIMIT)" do
    @topk_rows [
      %{"v" => 5},
      %{"v" => 1},
      %{"v" => 4},
      %{"v" => 2},
      %{"v" => 3}
    ]

    test "ORDER BY ASC + LIMIT returns the correctly sorted, truncated prefix" do
      query = %Query{
        source: ["items"],
        order_bys: [{["v"], :asc}],
        limit: 2,
        select: [{:field, ["v"]}]
      }

      assert {:ok, rows} = run_against(query, %{["items"] => @topk_rows})
      assert rows == [%{"v" => 1}, %{"v" => 2}]
    end

    test "ORDER BY DESC + LIMIT returns the correctly sorted, truncated prefix" do
      query = %Query{
        source: ["items"],
        order_bys: [{["v"], :desc}],
        limit: 2,
        select: [{:field, ["v"]}]
      }

      assert {:ok, rows} = run_against(query, %{["items"] => @topk_rows})
      assert rows == [%{"v" => 5}, %{"v" => 4}]
    end

    test "ORDER BY + LIMIT + OFFSET returns the correct window, not just the correct prefix" do
      query = %Query{
        source: ["items"],
        order_bys: [{["v"], :asc}],
        limit: 2,
        offset: 2,
        select: [{:field, ["v"]}]
      }

      assert {:ok, rows} = run_against(query, %{["items"] => @topk_rows})
      assert rows == [%{"v" => 3}, %{"v" => 4}]
    end

    test "LIMIT 0 with a real ORDER BY returns no rows, not a crash" do
      query = %Query{
        source: ["items"],
        order_bys: [{["v"], :asc}],
        limit: 0,
        select: [{:field, ["v"]}]
      }

      assert {:ok, []} = run_against(query, %{["items"] => @topk_rows})
    end

    test "a tie in the sort key breaks stably, same as Enum.sort/2's own documented guarantee" do
      rows = [%{"v" => 1, "tag" => "a"}, %{"v" => 1, "tag" => "b"}, %{"v" => 0, "tag" => "c"}]

      query = %Query{
        source: ["items"],
        order_bys: [{["v"], :asc}],
        limit: 3,
        select: [{:field, ["tag"]}]
      }

      assert {:ok, rows} = run_against(query, %{["items"] => rows})
      assert rows == [%{"tag" => "c"}, %{"tag" => "a"}, %{"tag" => "b"}]
    end

    test "DISTINCT still forces the full materialize-then-sort path -- unaffected by this feature" do
      rows = [%{"v" => 2}, %{"v" => 1}, %{"v" => 1}, %{"v" => 2}]

      query = %Query{
        source: ["items"],
        order_bys: [{["v"], :asc}],
        limit: 5,
        distinct: true,
        select: [{:field, ["v"]}]
      }

      assert {:ok, rows} = run_against(query, %{["items"] => rows})
      assert rows == [%{"v" => 1}, %{"v" => 2}]
    end

    property "always matches a naive Enum.sort_by/2 + Enum.slice/2 reference implementation" do
      check all(
              values <- list_of(integer(-50..50), min_length: 0, max_length: 30),
              limit <- integer(0..10),
              offset <- integer(0..10),
              direction <- member_of([:asc, :desc])
            ) do
        rows = Enum.map(values, &%{"v" => &1})

        query = %Query{
          source: ["items"],
          order_bys: [{["v"], direction}],
          limit: limit,
          offset: offset,
          select: [{:field, ["v"]}]
        }

        assert {:ok, actual} = run_against(query, %{["items"] => rows})

        sorter = if direction == :asc, do: &<=/2, else: &>=/2

        expected =
          values
          |> Enum.sort(sorter)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(&%{"v" => &1})

        assert actual == expected
      end
    end
  end

  describe "GROUP BY ... ROLLUP / CUBE (lang_spec.md §5.2)" do
    @rollup_select [
      {:field, ["region"]},
      {:field, ["quarter"]},
      {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
    ]

    test "ROLLUP produces detail rows, a subtotal per region, and a grand total" do
      query = %Query{
        source: ["sales"],
        group_bys: [["region"], ["quarter"]],
        group_mode: :rollup,
        select: @rollup_select
      }

      assert {:ok, rows} = run(query)

      assert Enum.sort(rows) ==
               Enum.sort([
                 %{"region" => "east", "quarter" => "q1", "total" => 100},
                 %{"region" => "east", "quarter" => "q2", "total" => 150},
                 %{"region" => "east", "quarter" => nil, "total" => 250},
                 %{"region" => "west", "quarter" => "q1", "total" => 200},
                 %{"region" => "west", "quarter" => "q2", "total" => 50},
                 %{"region" => "west", "quarter" => nil, "total" => 250},
                 %{"region" => nil, "quarter" => nil, "total" => 500}
               ])
    end

    test "with no explicit ORDER BY, rows come back finest detail first, grand total last" do
      query = %Query{
        source: ["sales"],
        group_bys: [["region"], ["quarter"]],
        group_mode: :rollup,
        select: @rollup_select
      }

      assert {:ok, rows} = run(query)

      {detail_rows, rest} = Enum.split(rows, 4)
      {subtotal_rows, [grand_total]} = Enum.split(rest, 2)

      assert Enum.all?(detail_rows, fn r -> r["region"] != nil and r["quarter"] != nil end)
      assert Enum.all?(subtotal_rows, fn r -> r["region"] != nil and r["quarter"] == nil end)
      assert grand_total == %{"region" => nil, "quarter" => nil, "total" => 500}
    end

    test "CUBE adds a per-quarter subtotal (region rolled up) too, not just per-region" do
      query = %Query{
        source: ["sales"],
        group_bys: [["region"], ["quarter"]],
        group_mode: :cube,
        select: @rollup_select
      }

      assert {:ok, rows} = run(query)

      # Every ROLLUP row, unordered, still shows up in CUBE's own output --
      # ROLLUP is a strict subset of CUBE's own grouping levels (the
      # right-to-left prefixes, out of every subset).
      rollup_query = %Query{query | group_mode: :rollup}
      assert {:ok, rollup_rows} = run(rollup_query)
      assert Enum.sort(rollup_rows) -- Enum.sort(rows) == []

      # CUBE's own extra levels: quarter alone (region rolled up).
      assert %{"region" => nil, "quarter" => "q1", "total" => 300} in rows
      assert %{"region" => nil, "quarter" => "q2", "total" => 200} in rows

      # 4 detail + 2 region subtotals + 2 quarter subtotals + 1 grand
      # total = 2^2 grouping levels' worth of rows, one row per distinct
      # key at each level.
      assert length(rows) == 9
    end

    test "a single-column ROLLUP is just a grand total added to the plain grouping" do
      query = %Query{
        source: ["sales"],
        group_bys: [["region"]],
        group_mode: :rollup,
        select: [
          {:field, ["region"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.sort(rows) ==
               Enum.sort([
                 %{"region" => "east", "total" => 250},
                 %{"region" => "west", "total" => 250},
                 %{"region" => nil, "total" => 500}
               ])
    end

    test "HAVING filters every ROLLUP/CUBE level's own groups, not just the finest one" do
      query = %Query{
        source: ["sales"],
        group_bys: [["region"]],
        group_mode: :rollup,
        havings: [{:cmp, :gt, {:call, "sum", [{:field, ["amount"]}]}, 300}],
        select: [
          {:field, ["region"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query)

      # Both region subtotals (250 each) fail HAVING; only the 500 grand
      # total survives.
      assert rows == [%{"region" => nil, "total" => 500}]
    end

    test "a group_mode: :plain query behaves exactly as it did before ROLLUP/CUBE existed (regression)" do
      query = %Query{
        source: ["sales"],
        group_bys: [["region"]],
        group_mode: :plain,
        order_bys: [{["region"], :asc}],
        select: [
          {:field, ["region"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"region" => "east", "total" => 250},
               %{"region" => "west", "total" => 250}
             ]

      refute Enum.any?(rows, fn row -> is_nil(row["region"]) end)
    end
  end

  describe "WITH named sub-queries" do
    test "a query whose source is a WITH-bound name runs the binding instead of fetching" do
      query = %Query{
        source: ["active_users"],
        select: [{:field, ["name"]}],
        with_bindings: %{
          "active_users" => %Query{
            source: ["users"],
            wheres: [{:cmp, :eq, ["status"], "active"}],
            select: [{:field, ["name"]}]
          }
        }
      }

      assert {:ok, rows} = run(query)
      assert rows == [%{"name" => "Alice"}]
    end

    test "a bare name with no matching WITH binding falls through to a real source, not an error" do
      query = %Query{
        source: ["users"],
        select: [{:field, ["name"]}],
        with_bindings: %{"unrelated" => %Query{source: ["orders"], select: []}}
      }

      assert {:ok, [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Carol"}]} = run(query)
    end

    test "a WITH binding can itself reference another WITH binding" do
      # base: age > 20 keeps Alice (30) and Carol (65), drops Bob (17).
      # filtered: age < 40 on top of base keeps only Alice -- proves a
      # real two-step narrowing, not a coincidence of either filter
      # alone.
      query = %Query{
        source: ["filtered"],
        select: [{:field, ["name"]}],
        with_bindings: %{
          "base" => %Query{
            source: ["users"],
            wheres: [{:cmp, :gt, ["age"], 20}],
            select: [{:field, ["name"]}, {:field, ["age"]}]
          },
          "filtered" => %Query{
            source: ["base"],
            wheres: [{:cmp, :lt, ["age"], 40}],
            select: [{:field, ["name"]}]
          }
        }
      }

      assert {:ok, [%{"name" => "Alice"}]} = run(query)
    end

    test "with_bindings threads through a nested SELECT and correlates normally" do
      query = %Query{
        source: ["customers"],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: ["big_orders"],
            wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
            select: [{:field, ["total"]}]
          }
        ],
        with_bindings: %{
          "big_orders" => %Query{
            source: ["customer_orders"],
            wheres: [{:cmp, :gt, ["total"], 60}],
            select: [{:field, ["id"]}, {:field, ["customer_id"]}, {:field, ["total"]}]
          }
        }
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"name" => "Alice", "big_orders" => [%{"total" => 75}]},
               %{"name" => "Bob", "big_orders" => []},
               %{"name" => "Carol", "big_orders" => []}
             ]
    end

    test "an unfiltered WITH binding composes with per-outer-row correlation around it" do
      # own_orders itself has no WHERE -- the *outer* nested SELECT's own
      # correlated WHERE is what narrows it down differently per outer
      # row, proving the binding's rows are fetched fresh at each
      # reference rather than some single, stale execution reused
      # everywhere.
      query = %Query{
        source: ["customers"],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: ["own_orders"],
            wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
            select: [{:field, ["id"]}]
          }
        ],
        with_bindings: %{
          "own_orders" => %Query{
            source: ["customer_orders"],
            select: [{:field, ["id"]}, {:field, ["customer_id"]}]
          }
        }
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"name" => "Alice", "own_orders" => [%{"id" => 100}, %{"id" => 101}]},
               %{"name" => "Bob", "own_orders" => []},
               %{"name" => "Carol", "own_orders" => [%{"id" => 102}]}
             ]
    end
  end

  describe "query combinators (UNION / UNION ALL / INTERSECT / EXCEPT)" do
    defp combined(op, left, right), do: %CombinedQuery{op: op, left: left, right: right}

    @team_a_query %Query{source: ["team_a"], select: [{:field, ["name"]}]}
    @team_b_query %Query{source: ["team_b"], select: [{:field, ["name"]}]}

    test "UNION concatenates and dedupes, including an in-source duplicate" do
      assert {:ok, rows} = run(combined(:union, @team_a_query, @team_b_query))

      assert rows == [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Carol"}]
    end

    test "UNION still dedupes correctly, and returns plain maps, when both sides are Scry.Core.Row values" do
      assert run_via_row_engine(combined(:union, @team_a_query, @team_b_query)) ==
               run(combined(:union, @team_a_query, @team_b_query))
    end

    test "UNION ALL concatenates without deduping" do
      assert {:ok, rows} = run(combined(:union_all, @team_a_query, @team_b_query))

      assert rows == [
               %{"name" => "Alice"},
               %{"name" => "Bob"},
               %{"name" => "Alice"},
               %{"name" => "Bob"},
               %{"name" => "Carol"}
             ]
    end

    test "INTERSECT keeps only rows present in both, deduped" do
      assert {:ok, rows} = run(combined(:intersect, @team_a_query, @team_b_query))
      assert rows == [%{"name" => "Bob"}]
    end

    test "EXCEPT keeps only left-side rows absent from the right, deduped" do
      assert {:ok, rows} = run(combined(:except, @team_a_query, @team_b_query))
      assert rows == [%{"name" => "Alice"}]
    end

    test "each side applies its own WHERE/ORDER BY/LIMIT independently before combining" do
      left = %Query{
        source: ["team_a"],
        wheres: [{:cmp, :not_eq, ["name"], "Bob"}],
        select: [{:field, ["name"]}]
      }

      right = %Query{source: ["team_b"], limit: 1, select: [{:field, ["name"]}]}

      assert {:ok, rows} = run(combined(:union, left, right))
      # left: Alice only (Bob filtered out, its own duplicate deduped
      # away too); right: Bob only (LIMIT 1, fetch order Bob, Carol).
      assert rows == [%{"name" => "Alice"}, %{"name" => "Bob"}]
    end

    test "an error on either side propagates, not silently dropped" do
      bad = %Query{source: ["nonexistent"], select: []}

      assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} =
               run(combined(:union, @team_a_query, bad))

      assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} =
               run(combined(:union, bad, @team_a_query))
    end

    test "a 3-way chain composes correctly: (A UNION B) EXCEPT B" do
      chain = combined(:except, combined(:union, @team_a_query, @team_b_query), @team_b_query)
      assert {:ok, rows} = run(chain)
      assert rows == [%{"name" => "Alice"}]
    end

    test "a WITH binding whose own value is a %CombinedQuery{} still resolves via run_any/6" do
      # Not reachable through the parser today (WITH's own grammar
      # rule stays plain `select`, Scry.Core.CombinedQuery's own
      # moduledoc has the reasoning) -- this constructs the shape by
      # hand to verify Scry.Core.Executor's own dispatch stays generic
      # regardless, not just by inspection of the code.
      query = %Query{
        source: ["merged"],
        select: [{:field, ["name"]}],
        with_bindings: %{"merged" => combined(:union, @team_a_query, @team_b_query)}
      }

      assert {:ok, rows} = run(query)
      assert rows == [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Carol"}]
    end
  end

  describe "explicit casts (string / int / exact / inexact)" do
    # @products: Widget price 3 cost 4, Gadget price 4 cost 2 -- reused
    # from the top-level fixtures.

    test "a cast in a computed field is an ordinary per-row expression -- one row per source row" do
      # The load-bearing regression check: a call used to unconditionally
      # force grouped/flat-aggregate execution, which would have wrongly
      # collapsed this into a single row.
      query = %Query{
        source: ["products"],
        select: [{:field, ["name"]}, {:computed, "p", {:call, "string", [{:field, ["price"]}]}}]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"name" => "Widget", "p" => "3"},
               %{"name" => "Gadget", "p" => "4"}
             ]
    end

    test "string/1 over its own representative value domain" do
      assert cast("string", 5) == "5"
      assert cast("string", Rational.new(3, 4)) == "3/4"
      assert cast("string", 2.5) == "2.5"
      assert cast("string", "already a string") == "already a string"
      assert cast("string", true) == "true"
      assert cast("string", false) == "false"
      assert cast("string", nil) == "nil"
      assert cast("string", ~D[2026-01-01]) == "2026-01-01"
      assert cast("string", {:atom, "active"}) == "active"
    end

    test "string/1 raises for an unsupported value type" do
      assert_raise ArgumentError, ~r/string\(\.\.\.\) does not support/, fn ->
        cast("string", [1, 2, 3])
      end
    end

    test "int/1 truncates toward zero, exactly, for a %Rational{} or a float" do
      assert cast("int", 5) == 5
      assert cast("int", Rational.new(7, 2)) == 3
      assert cast("int", Rational.new(-7, 2)) == -3
      assert cast("int", 3.9) == 3
      assert cast("int", -3.9) == -3
      assert cast("int", "42") == 42
    end

    test "int/1 raises for a non-integer string or an unsupported type" do
      assert_raise ArgumentError, ~r/could not parse/, fn -> cast("int", "not a number") end
      assert_raise ArgumentError, ~r/does not support/, fn -> cast("int", true) end
    end

    test "exact/1 is identity over already-exact values, converts a float" do
      assert cast("exact", 5) == 5
      assert cast("exact", Rational.new(1, 2)) == Rational.new(1, 2)
      assert cast("exact", 0.5) == Rational.new(1, 2)
    end

    test "exact/1 raises for an unsupported type" do
      assert_raise ArgumentError, ~r/does not support/, fn -> cast("exact", "5") end
    end

    test "inexact/1 converts an integer or %Rational{} to a float" do
      assert cast("inexact", 4) === 4.0
      assert cast("inexact", Rational.new(1, 4)) === 0.25
    end

    test "inexact(...) contagion reaches real arithmetic end to end, not just Rational's own unit tests" do
      query = %Query{
        source: ["products"],
        select: [
          {:field, ["name"]},
          {:computed, "half", {:arith, :div, {:call, "inexact", [{:field, ["price"]}]}, 2}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"name" => "Widget", "half" => 1.5},
               %{"name" => "Gadget", "half" => 2.0}
             ]
    end

    test "comparing a cast-produced float against an ordinary exact row value works via term_order" do
      query = %Query{
        source: ["products"],
        wheres: [{:cmp, :gt, {:call, "inexact", [{:field, ["price"]}]}, Rational.new(7, 2)}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Gadget"}]} = run(query)
    end

    test "a cast wrapping an aggregate inside a grouped query composes via the shared resolver" do
      query = %Query{
        source: ["products"],
        group_bys: [["name"]],
        select: [
          {:field, ["name"]},
          {:computed, "total", {:call, "string", [{:call, "sum", [{:field, ["price"]}]}]}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"name" => "Widget", "total" => "3"},
               %{"name" => "Gadget", "total" => "4"}
             ]
    end

    test "an aggregate referenced from an ordinary per-row WHERE (never grouped) still raises the clear error" do
      # WHERE isn't checked by aggregate_query? at all (matches SQL's own
      # "WHERE can't reference aggregates" rule), so this is genuinely
      # per-row -- the real path that should hit the rejection, not the
      # (different, correct) flat-aggregate collapse a bare aggregate in
      # `select` itself would trigger instead.
      query = %Query{
        source: ["products"],
        wheres: [{:cmp, :gt, {:call, "sum", [{:field, ["price"]}]}, 1}],
        select: [{:field, ["name"]}]
      }

      assert_raise ArgumentError, ~r/only valid inside GROUP BY\/HAVING/, fn -> run(query) end
    end

    test "an unknown function name still raises a clear error" do
      query = %Query{
        source: ["products"],
        select: [{:computed, "x", {:call, "foo", [{:field, ["price"]}]}}]
      }

      assert_raise ArgumentError, ~r/unknown or unsupported function/, fn -> run(query) end
    end

    test "a cast called with the wrong number of arguments raises" do
      query = %Query{
        source: ["products"],
        select: [{:computed, "x", {:call, "string", [{:field, ["price"]}, {:field, ["cost"]}]}}]
      }

      assert_raise ArgumentError, ~r/expects exactly one argument/, fn -> run(query) end
    end

    defp cast(name, value) do
      query = %Query{
        source: ["products"],
        limit: 1,
        select: [{:computed, "x", {:call, name, [value]}}]
      }

      {:ok, [%{"x" => result}]} = run(query)
      result
    end
  end

  describe "count(distinct ...)" do
    # @customer_orders: customer_id 1 has two orders (100, 101),
    # customer_id 3 has one (102) -- distinct customer_ids = {1, 3}.

    test "a flat count(distinct ...), no explicit GROUP BY" do
      query = %Query{
        source: ["customer_orders"],
        select: [
          {:computed, "distinct_customers",
           {:call, "count", [{:distinct, {:field, ["customer_id"]}}]}}
        ]
      }

      assert {:ok, [%{"distinct_customers" => 2}]} = run(query)
    end

    test "a grouped count(distinct ...)" do
      query = %Query{
        source: ["order_items"],
        group_bys: [["order_id"]],
        select: [
          {:field, ["order_id"]},
          {:computed, "skus", {:call, "count", [{:distinct, {:field, ["sku"]}}]}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1["skus"] == 1))
    end

    test "an ordinary (non-distinct) count is completely unaffected" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "n", {:call, "count", [{:field, ["id"]}]}}]
      }

      assert {:ok, [%{"n" => 3}]} = run(query)
    end

    test "a cast wrapping an aggregate is detected without an explicit GROUP BY (regression)" do
      # Found while implementing count(distinct ...): the aggregate-
      # detection family used to only check a call's own outer name, not
      # recurse into its args, so a cast wrapping an aggregate
      # (string(count(distinct ...)), or even just string(sum(x))) never
      # triggered grouped/flat-aggregate execution at all without an
      # explicit GROUP BY, and instead hit the per-row rejection error.
      query = %Query{
        source: ["customer_orders"],
        select: [
          {:computed, "total",
           {:call, "string", [{:call, "count", [{:distinct, {:field, ["customer_id"]}}]}]}}
        ]
      }

      assert {:ok, [%{"total" => "2"}]} = run(query)
    end

    test "distinct hard-errors on a nil value, same as every other aggregate" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "x", {:call, "count", [{:distinct, {:field, ["missing"]}}]}}]
      }

      assert_raise ArgumentError, ~r/encountered a nil value/, fn -> run(query) end
    end

    test "distinct on sum/avg/min/max raises a clear error, not silently treated as a literal" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "x", {:call, "sum", [{:distinct, {:field, ["total"]}}]}}]
      }

      assert_raise ArgumentError, ~r/distinct is only valid inside count\(distinct/, fn ->
        run(query)
      end
    end

    test "distinct on a cast raises a clear error" do
      query = %Query{
        source: ["customer_orders"],
        select: [{:computed, "x", {:call, "string", [{:distinct, {:field, ["total"]}}]}}]
      }

      assert_raise ArgumentError, ~r/distinct is only valid inside count\(distinct/, fn ->
        run(query)
      end
    end
  end

  describe "extended standard aggregates (stddev/var/percentile, lang_spec.md §5.8)" do
    test "var_pop/stddev_pop over the whole set, no explicit GROUP BY" do
      query = %Query{
        source: ["measurements"],
        select: [
          {:computed, "var_pop", {:call, "var_pop", [{:field, ["v"]}]}},
          {:computed, "stddev_pop", {:call, "stddev_pop", [{:field, ["v"]}]}}
        ]
      }

      assert {:ok, [%{"var_pop" => 4, "stddev_pop" => 2.0}]} = run(query)
    end

    test "var_samp/stddev_samp use Bessel's correction (n - 1), not var_pop/stddev_pop's n" do
      query = %Query{
        source: ["measurements"],
        select: [
          {:computed, "var_samp", {:call, "var_samp", [{:field, ["v"]}]}},
          {:computed, "stddev_samp", {:call, "stddev_samp", [{:field, ["v"]}]}}
        ]
      }

      assert {:ok, [%{"var_samp" => var_samp, "stddev_samp" => stddev_samp}]} = run(query)
      assert var_samp == Rational.new(32, 7)
      assert_in_delta stddev_samp, :math.sqrt(32 / 7), 0.0000001
    end

    test "stddev_pop/var_pop of a single-row group is 0, not nil (a defined answer, unlike _samp)" do
      query = %Query{
        source: ["measurements"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [
          {:computed, "var_pop", {:call, "var_pop", [{:field, ["v"]}]}},
          {:computed, "stddev_pop", {:call, "stddev_pop", [{:field, ["v"]}]}}
        ]
      }

      assert {:ok, [%{"var_pop" => 0, "stddev_pop" => stddev_pop}]} = run(query)
      assert stddev_pop == 0.0
    end

    test "var_samp/stddev_samp of a single-row group is nil -- undefined below 2 data points" do
      query = %Query{
        source: ["measurements"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [
          {:computed, "var_samp", {:call, "var_samp", [{:field, ["v"]}]}},
          {:computed, "stddev_samp", {:call, "stddev_samp", [{:field, ["v"]}]}}
        ]
      }

      assert {:ok, [%{"var_samp" => nil, "stddev_samp" => nil}]} = run(query)
    end

    test "var_pop/stddev_pop of an empty group is nil, same empty-aggregate convention as sum/avg" do
      query = %Query{
        source: ["measurements"],
        wheres: [{:cmp, :eq, ["id"], -1}],
        select: [
          {:computed, "var_pop", {:call, "var_pop", [{:field, ["v"]}]}},
          {:computed, "stddev_pop", {:call, "stddev_pop", [{:field, ["v"]}]}}
        ]
      }

      assert {:ok, [%{"var_pop" => nil, "stddev_pop" => nil}]} = run(query)
    end

    test "a GROUP BY/HAVING using a new aggregate composes exactly like sum/avg/min/max already do" do
      grouped = [
        %{"id" => 1, "grp" => "a", "v" => 2},
        %{"id" => 2, "grp" => "a", "v" => 4},
        %{"id" => 3, "grp" => "b", "v" => 100},
        %{"id" => 4, "grp" => "b", "v" => 100}
      ]

      query = %Query{
        source: ["measurements"],
        group_bys: [["grp"]],
        havings: [{:cmp, :gt, {:call, "stddev_pop", [{:field, ["v"]}]}, 0}],
        select: [
          {:field, ["grp"]},
          {:computed, "sd", {:call, "stddev_pop", [{:field, ["v"]}]}}
        ]
      }

      data = Map.put(@data, ["measurements"], grouped)

      assert {:ok, [%{"grp" => "a", "sd" => 1.0}]} =
               Executor.run(query, FakeEngine, data) |> materialize()
    end

    test "distinct on a new aggregate raises the same clear error sum/avg/min/max already do" do
      query = %Query{
        source: ["measurements"],
        select: [{:computed, "x", {:call, "stddev_pop", [{:distinct, {:field, ["v"]}}]}}]
      }

      assert_raise ArgumentError, ~r/distinct is only valid inside count\(distinct/, fn ->
        run(query)
      end
    end

    test "a nil value hard-errors, same as every other aggregate" do
      query = %Query{
        source: ["measurements"],
        select: [{:computed, "x", {:call, "var_pop", [{:field, ["missing"]}]}}]
      }

      assert_raise ArgumentError, ~r/encountered a nil value/, fn -> run(query) end
    end

    test "percentile(expr, p) -- p = 0/0.5/1 pick the min/median/max via nearest-rank" do
      query = %Query{
        source: ["measurements"],
        select: [
          {:computed, "p0", {:call, "percentile", [{:field, ["v"]}, 0]}},
          {:computed, "p50", {:call, "percentile", [{:field, ["v"]}, Rational.new(1, 2)]}},
          {:computed, "p100", {:call, "percentile", [{:field, ["v"]}, 1]}}
        ]
      }

      assert {:ok, [%{"p0" => 2, "p50" => 4, "p100" => 9}]} = run(query)
    end

    test "percentile's own p can be a field, resolved once against the representative row" do
      # p isn't required to be a literal -- it's an ordinary expr(), the
      # same as any other aggregate's own argument. Every row here
      # carries the identical "threshold" value, so this doesn't
      # distinguish "resolved once" from "resolved per row" on its own,
      # but it does confirm the field-reference code path for `p`
      # (`resolve_rhs({:field, ...}, representative(member_rows), ...)`)
      # actually works end to end, not just the literal-integer/Rational
      # cases the other tests in this block already cover.
      rows = Enum.map(@measurements, &Map.put(&1, "threshold", Rational.new(1, 2)))
      data = Map.put(@data, ["measurements"], rows)

      query = %Query{
        source: ["measurements"],
        select: [
          {:computed, "p50", {:call, "percentile", [{:field, ["v"]}, {:field, ["threshold"]}]}}
        ]
      }

      assert {:ok, [%{"p50" => 4}]} = Executor.run(query, FakeEngine, data) |> materialize()
    end

    test "percentile hard-errors on a nil value in its value argument" do
      query = %Query{
        source: ["measurements"],
        select: [{:computed, "x", {:call, "percentile", [{:field, ["missing"]}, 0]}}]
      }

      assert_raise ArgumentError, ~r/encountered a nil value/, fn -> run(query) end
    end

    test "percentile's own p outside [0, 1] raises a clear error" do
      query = %Query{
        source: ["measurements"],
        select: [{:computed, "x", {:call, "percentile", [{:field, ["v"]}, 2]}}]
      }

      assert_raise ArgumentError, ~r/p must be between 0 and 1, got: 2/, fn -> run(query) end
    end

    test "percentile with the wrong arity raises a clear error, not a raw FunctionClauseError" do
      query = %Query{
        source: ["measurements"],
        select: [{:computed, "x", {:call, "percentile", [{:field, ["v"]}]}}]
      }

      assert_raise ArgumentError, ~r/percentile\/2 expects exactly two arguments/, fn ->
        run(query)
      end
    end

    test "distinct on percentile's own value argument raises a clear error" do
      query = %Query{
        source: ["measurements"],
        select: [
          {:computed, "x", {:call, "percentile", [{:distinct, {:field, ["v"]}}, 0]}}
        ]
      }

      assert_raise ArgumentError, ~r/distinct is only valid inside count\(distinct/, fn ->
        run(query)
      end
    end

    test "a cast wrapping a new aggregate is detected without an explicit GROUP BY" do
      query = %Query{
        source: ["measurements"],
        select: [
          {:computed, "sd", {:call, "string", [{:call, "stddev_pop", [{:field, ["v"]}]}]}}
        ]
      }

      assert {:ok, [%{"sd" => "2.0"}]} = run(query)
    end
  end

  describe "rate(<duration>) aggregate (lang_spec.md §5.8/§8.2)" do
    test "count(rows) * duration / elapsed, GROUP BY-scoped, via a DateTime timestamp field" do
      query = %Query{
        source: ["rate_events"],
        group_bys: [["service"]],
        order_bys: [{["service"], :asc}],
        time_field: ["at"],
        select: [
          {:field, ["service"]},
          {:computed, "r", {:call, "rate", [30]}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert rows == [
               %{"service" => "svc-a", "r" => 1},
               %{"service" => "svc-b", "r" => Rational.new(3, 2)}
             ]
    end

    test "the same computation via a NaiveDateTime timestamp field, no GROUP BY at all" do
      query = %Query{
        source: ["rate_events_naive"],
        time_field: ["at"],
        select: [{:computed, "r", {:call, "rate", [30]}}]
      }

      assert {:ok, [%{"r" => r}]} = run(query)
      assert r == Rational.new(3, 2)
    end

    test "with no LAST ... OF <field> clause in the query, time_field stays nil and this is a clear error" do
      query = %Query{
        source: ["rate_events"],
        select: [{:computed, "r", {:call, "rate", [30]}}]
      }

      assert_raise ArgumentError, ~r/needs a LAST <duration> OF <field> clause/, fn ->
        run(query)
      end
    end

    test "an empty group is nil, same empty-aggregate convention as sum/avg" do
      query = %Query{
        source: ["rate_events"],
        wheres: [{:cmp, :eq, ["service"], "nonexistent"}],
        time_field: ["at"],
        select: [{:computed, "r", {:call, "rate", [30]}}]
      }

      assert {:ok, [%{"r" => nil}]} = run(query)
    end

    test "a single-row group is nil -- no elapsed interval to measure a density against" do
      query = %Query{
        source: ["rate_events"],
        wheres: [{:cmp, :eq, ["at"], ~U[2026-01-01 00:00:40.000000Z]}],
        time_field: ["at"],
        select: [{:computed, "r", {:call, "rate", [30]}}]
      }

      assert {:ok, [%{"r" => nil}]} = run(query)
    end

    test "a nil value in the query's own time_field hard-errors, same as every other aggregate" do
      rows = [
        %{"service" => "x", "at" => nil},
        %{"service" => "x", "at" => ~U[2026-01-01 00:00:00.000000Z]}
      ]

      data = Map.put(@data, ["rate_events"], rows)

      query = %Query{
        source: ["rate_events"],
        time_field: ["at"],
        select: [{:computed, "r", {:call, "rate", [30]}}]
      }

      assert_raise ArgumentError, ~r/encountered a nil value.*LAST/s, fn ->
        Executor.run(query, FakeEngine, data) |> materialize()
      end
    end

    test "the wrong arity raises a clear error, not a raw FunctionClauseError" do
      query = %Query{
        source: ["rate_events"],
        time_field: ["at"],
        select: [{:computed, "r", {:call, "rate", []}}]
      }

      assert_raise ArgumentError, ~r/rate\/1 expects exactly one argument/, fn -> run(query) end
    end

    test "HAVING rate(...) > x works, and does so via the eager (non-streaming) path" do
      # rate is deliberately not in @streaming_capable_aggregate_names --
      # if it were mistakenly treated as streamable with no init_agg/
      # update_agg/merge_agg/finalize_agg clauses of its own, this would
      # crash with a FunctionClauseError instead of returning the
      # correct, hand-computed answer.
      query = %Query{
        source: ["rate_events"],
        group_bys: [["service"]],
        havings: [{:cmp, :gt, {:call, "rate", [30]}, 1}],
        time_field: ["at"],
        select: [
          {:field, ["service"]},
          {:computed, "r", {:call, "rate", [30]}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert rows == [%{"service" => "svc-b", "r" => Rational.new(3, 2)}]
    end

    test "rate(...) OVER (PARTITION BY ...) works as a window function, without collapsing row count" do
      query = %Query{
        source: ["rate_events"],
        time_field: ["at"],
        select: [
          {:field, ["service"]},
          {:computed, "r", {:window, {:call, "rate", [30]}, [["service"]], [], nil}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert length(rows) == length(@rate_events)

      assert rows |> Enum.filter(&(&1["service"] == "svc-a")) |> Enum.all?(&(&1["r"] == 1))

      assert rows
             |> Enum.filter(&(&1["service"] == "svc-b"))
             |> Enum.all?(&(&1["r"] == Rational.new(3, 2)))
    end

    test "used as an ordinary per-row expression (never grouped) raises the clear aggregate error" do
      query = %Query{
        source: ["rate_events"],
        wheres: [{:cmp, :gt, {:call, "rate", [30]}, 1}],
        time_field: ["at"],
        select: [{:field, ["service"]}]
      }

      assert_raise ArgumentError, ~r/only valid inside GROUP BY\/HAVING/, fn -> run(query) end
    end

    property "always matches a naive reference implementation: count * duration / elapsed" do
      check all(
              offsets <- list_of(integer(0..3600), min_length: 0, max_length: 20),
              duration <- integer(1..120)
            ) do
        base = ~U[2026-01-01 00:00:00.000000Z]
        rows = Enum.map(offsets, &%{"at" => DateTime.add(base, &1, :second)})
        data = Map.put(@data, ["rate_events"], rows)

        query = %Query{
          source: ["rate_events"],
          time_field: ["at"],
          select: [{:computed, "r", {:call, "rate", [duration]}}]
        }

        assert {:ok, [%{"r" => actual}]} = Executor.run(query, FakeEngine, data) |> materialize()

        {min_o, max_o} = if offsets == [], do: {0, 0}, else: Enum.min_max(offsets)

        if length(offsets) <= 1 or max_o == min_o do
          assert actual == nil
        else
          expected = Rational.new(length(offsets) * duration, max_o - min_o)
          assert Rational.compare(actual, expected) == :eq
        end
      end
    end
  end

  describe "json(<field>).path (lang_spec.md §5.8/§7)" do
    test "WHERE json(<field>).path = ... -- the lang_spec.md §7 worked example" do
      query = %Query{
        source: ["tickets"],
        wheres: [
          {:cmp, :eq, {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["color"]}, "red"}
        ],
        select: [{:field, ["id"]}]
      }

      assert {:ok, [%{"id" => 1}]} = run(query)
    end

    test "a computed field reading a nested path" do
      query = %Query{
        source: ["tickets"],
        select: [
          {:field, ["id"]},
          {:computed, "color", {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["color"]}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert rows == [%{"id" => 1, "color" => "red"}, %{"id" => 2, "color" => "blue"}]
    end

    test "a list-valued subfield resolves to an ordinary Elixir list" do
      query = %Query{
        source: ["tickets"],
        limit: 1,
        select: [{:computed, "tags", {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["tags"]}}]
      }

      assert {:ok, [%{"tags" => ["urgent", "new"]}]} = run(query)
    end

    test "json(...) used bare (no dot-path) returns the whole decoded value" do
      query = %Query{
        source: ["tickets"],
        limit: 1,
        select: [{:computed, "m", {:call, "json", [{:field, ["metadata"]}]}}]
      }

      assert {:ok, [%{"m" => %{"color" => "red", "tags" => ["urgent", "new"]}}]} = run(query)
    end

    test "json(...) on a non-string value raises a clear error" do
      query = %Query{
        source: ["tickets"],
        select: [{:computed, "m", {:call, "json", [{:field, ["id"]}]}}]
      }

      assert_raise ArgumentError, ~r/json\(\.\.\.\) only applies to a String value/, fn ->
        run(query)
      end
    end

    test "malformed JSON text raises a clear error, not a raw stdlib exception" do
      bad_data = Map.put(@data, ["tickets"], [%{"id" => 1, "metadata" => "not json"}])

      query = %Query{
        source: ["tickets"],
        select: [{:computed, "m", {:call, "json", [{:field, ["metadata"]}]}}]
      }

      assert_raise ArgumentError, ~r/could not parse this value as JSON/, fn ->
        Executor.run(query, FakeEngine, bad_data) |> elem(1) |> Cursor.to_list()
      end
    end

    test "a call wrapping an aggregate, via {:dot, ...}, is still detected without an explicit GROUP BY" do
      # Same regression class as count(distinct ...)'s own fix --
      # {:dot, ...}'s own aggregate-detection recursion, verified for
      # real, not just by inspection. customer_orders' own three rows
      # (total 50 + 75 + 20) sum to 145 -- string(sum(total)) collapsing
      # to "145" (not, say, "50" or crashing on the per-row rejection
      # error) is only possible if grouped/flat-aggregate execution
      # actually fired; walking a bogus path into that string then
      # raises BadMapError, an *expected*, different failure that
      # itself proves the aggregate was correctly computed first.
      query = %Query{
        source: ["customer_orders"],
        select: [
          {:computed, "total",
           {:dot, {:call, "string", [{:call, "sum", [{:field, ["total"]}]}]}, ["nonexistent"]}}
        ]
      }

      assert_raise BadMapError, ~r/"145"/, fn -> run(query) end
    end
  end

  describe "in against a computed list (lang_spec.md §7)" do
    test "a literal on the left against a plain field path -- the lang_spec.md §7 worked example" do
      query = %Query{
        source: ["cards"],
        wheres: [{:in, {:literal, "urgent"}, {:field, ["metadata", "tags"]}}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, [%{"id" => 1}]} = run(query)
    end

    test "no match against the computed list is excluded, not raised" do
      query = %Query{
        source: ["cards"],
        wheres: [{:in, {:literal, "urgent"}, {:field, ["metadata", "tags"]}}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, rows} = run(query)
      refute Enum.any?(rows, &(&1["id"] in [2, 3]))
    end

    test "a field on the left against a computed list too, not just a literal" do
      query = %Query{
        source: ["users"],
        wheres: [{:in, ["status"], {:field, ["status_allowlist"]}}],
        select: [{:field, ["name"]}]
      }

      data =
        Map.put(@data, ["users"], [
          %{"name" => "Alice", "status" => "active", "status_allowlist" => ["active"]},
          %{"name" => "Bob", "status" => "pending", "status_allowlist" => ["active"]}
        ])

      assert {:ok, [%{"name" => "Alice"}]} =
               Executor.run(query, FakeEngine, data) |> materialize()
    end

    test "a call narrowed by a dot-path as the computed list -- json(<field>).path composes with in" do
      query = %Query{
        source: ["tickets"],
        wheres: [
          {:in, {:literal, "urgent"}, {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["tags"]}}
        ],
        select: [{:field, ["id"]}]
      }

      assert {:ok, [%{"id" => 1}]} = run(query)
    end

    test "a bare call as the computed list, when the call itself returns a list" do
      data = Map.put(@data, ["tickets"], [%{"id" => 1, "metadata" => ~s(["urgent","new"])}])

      query = %Query{
        source: ["tickets"],
        wheres: [{:in, {:literal, "urgent"}, {:call, "json", [{:field, ["metadata"]}]}}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, [%{"id" => 1}]} = Executor.run(query, FakeEngine, data) |> materialize()
    end

    test "a resolved value that isn't a list raises a clear error, not Enum.member?'s own crash" do
      query = %Query{
        source: ["tickets"],
        wheres: [
          {:in, {:literal, "urgent"},
           {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["color"]}}
        ],
        select: [{:field, ["id"]}]
      }

      assert_raise ArgumentError, ~r/in \.\.\. expects a list value/, fn -> run(query) end
    end

    test "a HAVING using a computed list against a group's own representative row" do
      query = %Query{
        source: ["cards"],
        group_bys: [["id"]],
        havings: [{:in, {:literal, "urgent"}, {:field, ["metadata", "tags"]}}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, [%{"id" => 1}]} = run(query)
    end
  end

  describe "window functions (lang_spec.md §5.5/§5.8)" do
    test "the lang_spec.md §11 worked example -- row_number() OVER PARTITION BY ... ORDER BY ... DESC" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "rank",
           {:window, {:call, "row_number", []}, [["department"]], [{["salary"], :desc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["rank"]}) == %{
               "Alice" => 3,
               "Bob" => 1,
               "Carol" => 2,
               "Dave" => 2,
               "Eve" => 1
             }
    end

    test "a window function still augments correctly when its own input rows are Scry.Core.Row values (a WITH-bound source answered by a Row-returning engine)" do
      query = %Query{
        source: ["recent"],
        select: [
          {:field, ["name"]},
          {:computed, "rank",
           {:window, {:call, "row_number", []}, [["department"]], [{["salary"], :desc}], nil}}
        ],
        with_bindings: %{
          "recent" => %Query{
            source: ["employees"],
            select: [{:field, ["name"]}, {:field, ["department"]}, {:field, ["salary"]}]
          }
        }
      }

      assert run_via_row_engine(query) == run(query)
    end

    test "row_number() with no PARTITION BY treats the whole result as one partition" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "n", {:window, {:call, "row_number", []}, [], [{["salary"], :asc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["n"]}) == %{
               "Dave" => 1,
               "Alice" => 2,
               "Eve" => 3,
               "Bob" => 4,
               "Carol" => 5
             }
    end

    test "rank() gives tied rows the same rank and skips the next one, unlike row_number()" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "r",
           {:window, {:call, "rank", []}, [["department"]], [{["salary"], :desc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["r"]}) == %{
               "Alice" => 3,
               "Bob" => 1,
               "Carol" => 1,
               "Dave" => 2,
               "Eve" => 1
             }
    end

    test "rank() with no ORDER BY gives every row rank 1" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "r", {:window, {:call, "rank", []}, [["department"]], [], nil}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert Enum.all?(rows, &(&1["r"] == 1))
    end

    test "a running total via ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "running",
           {:window, {:call, "sum", [{:field, ["salary"]}]}, [["department"]],
            [{["salary"], :asc}], {:unbounded_preceding, :current_row}}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["running"]}) == %{
               "Alice" => 100,
               "Bob" => 220,
               "Carol" => 340,
               "Dave" => 90,
               "Eve" => 200
             }
    end

    test "first_value's default frame is the whole partition, regardless of ORDER BY -- the case SQL gets wrong" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "top",
           {:window, {:call, "first_value", [{:field, ["salary"]}]}, [["department"]],
            [{["salary"], :desc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["top"]}) == %{
               "Alice" => 120,
               "Bob" => 120,
               "Carol" => 120,
               "Dave" => 110,
               "Eve" => 110
             }
    end

    test "first_value with an explicit ROWS BETWEEN frame varies per row, unlike the default frame" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "v",
           {:window, {:call, "first_value", [{:field, ["salary"]}]}, [["department"]],
            [{["salary"], :desc}], {:current_row, {:following, 1}}}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["v"]}) == %{
               "Alice" => 100,
               "Bob" => 120,
               "Carol" => 120,
               "Dave" => 90,
               "Eve" => 110
             }
    end

    test "last_value picks the frame's own final row" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "bottom",
           {:window, {:call, "last_value", [{:field, ["salary"]}]}, [["department"]],
            [{["salary"], :desc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["bottom"]}) == %{
               "Alice" => 100,
               "Bob" => 100,
               "Carol" => 100,
               "Dave" => 90,
               "Eve" => 90
             }
    end

    test "percentile(expr, p) works as a window function too" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "p50",
           {:window, {:call, "percentile", [{:field, ["salary"]}, Rational.new(1, 2)]},
            [["department"]], [], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.into(rows, %{}, &{&1["name"], &1["p50"]}) == %{
               "Alice" => 120,
               "Bob" => 120,
               "Carol" => 120,
               "Dave" => 90,
               "Eve" => 90
             }
    end

    test "a window-wrapped aggregate does not collapse the row count, unlike a bare aggregate" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "s",
           {:window, {:call, "sum", [{:field, ["salary"]}]}, [["department"]], [], nil}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert length(rows) == length(@employees)
    end

    test "combining a real GROUP BY with a window function executes -- the window runs over the grouped output rows, not the raw source rows" do
      query = %Query{
        source: ["employees"],
        group_bys: [["department"]],
        select: [
          {:field, ["department"]},
          {:computed, "total", {:call, "sum", [{:field, ["salary"]}]}},
          {:computed, "rank", {:window, {:call, "row_number", []}, [], [{["total"], :desc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      # eng: 100+120+120=340, sales: 90+110=200 -- eng ranks first by its
      # own already-aggregated total, not by anything from a raw row.
      assert Enum.sort(rows) ==
               Enum.sort([
                 %{"department" => "eng", "total" => 340, "rank" => 1},
                 %{"department" => "sales", "total" => 200, "rank" => 2}
               ])
    end

    test "combining a flat (ungrouped) aggregate with a window function executes -- the window runs over the single flat-aggregate row" do
      query = %Query{
        source: ["employees"],
        select: [
          {:computed, "total", {:call, "sum", [{:field, ["salary"]}]}},
          {:computed, "n", {:window, {:call, "row_number", []}, [], [], nil}}
        ]
      }

      assert {:ok, [row]} = run(query)
      assert row == %{"total" => 540, "n" => 1}
    end

    test "HAVING filters groups before the window function ever sees them, not after" do
      query = %Query{
        source: ["employees"],
        group_bys: [["department"]],
        havings: [{:cmp, :gt, {:call, "sum", [{:field, ["salary"]}]}, 300}],
        select: [
          {:field, ["department"]},
          {:computed, "total", {:call, "sum", [{:field, ["salary"]}]}},
          {:computed, "rn", {:window, {:call, "row_number", []}, [], [], nil}}
        ]
      }

      assert {:ok, rows} = run(query)
      # Only "eng" (340 > 300) survives HAVING -- "sales" (200) never
      # reaches the window pass at all, so its absence can't be mistaken
      # for a window-side filter.
      assert rows == [%{"department" => "eng", "total" => 340, "rn" => 1}]
    end

    test "an aggregate-as-window function resolves its own argument against the grouped output's own alias, not the original per-row field" do
      query = %Query{
        source: ["employees"],
        group_bys: [["department"]],
        select: [
          {:field, ["department"]},
          {:computed, "total", {:call, "sum", [{:field, ["salary"]}]}},
          {:computed, "running",
           {:window, {:call, "sum", [{:field, ["total"]}]}, [], [{["department"], :asc}],
            {:unbounded_preceding, :current_row}}}
        ]
      }

      assert {:ok, rows} = run(query)

      # "eng" < "sales" lexically: eng (340) first, then sales (200) --
      # `sum(total)` here means "running sum of the *group's own* total
      # column," not the original per-row `salary`.
      assert Enum.into(rows, %{}, &{&1["department"], &1["running"]}) == %{
               "eng" => 340,
               "sales" => 540
             }
    end

    test "streaming-capable aggregates combined with a window function still produce the correct result" do
      # sum/count/avg/min/max (this query's own "total") are all
      # streaming-capable (streaming_aggregate_plan/1) -- confirms the
      # window pass composes correctly with either the streaming or the
      # eager grouped-aggregation path, not just the eager one.
      query = %Query{
        source: ["employees"],
        group_bys: [["department"]],
        select: [
          {:field, ["department"]},
          {:computed, "total", {:call, "sum", [{:field, ["salary"]}]}},
          {:computed, "rank", {:window, {:call, "row_number", []}, [], [{["total"], :desc}], nil}}
        ]
      }

      assert {:ok, rows} = run(query)

      assert Enum.sort(rows) ==
               Enum.sort([
                 %{"department" => "eng", "total" => 340, "rank" => 1},
                 %{"department" => "sales", "total" => 200, "rank" => 2}
               ])
    end

    test "combining ROLLUP with a window function still raises a clear error -- that combination remains out of scope" do
      query = %Query{
        source: ["employees"],
        group_bys: [["department"]],
        group_mode: :rollup,
        select: [
          {:field, ["department"]},
          {:computed, "n", {:window, {:call, "row_number", []}, [], [], nil}}
        ]
      }

      assert_raise ArgumentError, ~r/ROLLUP\/CUBE.*window function.*isn.t supported yet/, fn ->
        run(query)
      end
    end

    test "combining CUBE with a window function still raises a clear error -- that combination remains out of scope" do
      query = %Query{
        source: ["employees"],
        group_bys: [["department"]],
        group_mode: :cube,
        select: [
          {:field, ["department"]},
          {:computed, "n", {:window, {:call, "row_number", []}, [], [], nil}}
        ]
      }

      assert_raise ArgumentError, ~r/ROLLUP\/CUBE.*window function.*isn.t supported yet/, fn ->
        run(query)
      end
    end

    test "row_number()/rank() reject a non-zero argument count" do
      row_number_query = %Query{
        source: ["employees"],
        select: [
          {:computed, "n", {:window, {:call, "row_number", [{:field, ["salary"]}]}, [], [], nil}}
        ]
      }

      assert_raise ArgumentError, ~r/row_number\(\)\/0 expects no arguments, got 1/, fn ->
        run(row_number_query)
      end

      rank_query = %Query{
        source: ["employees"],
        select: [
          {:computed, "r", {:window, {:call, "rank", [{:field, ["salary"]}]}, [], [], nil}}
        ]
      }

      assert_raise ArgumentError, ~r/rank\(\)\/0 expects no arguments, got 1/, fn ->
        run(rank_query)
      end
    end

    test "first_value/last_value reject an argument count other than one" do
      query = %Query{
        source: ["employees"],
        select: [{:computed, "v", {:window, {:call, "first_value", []}, [], [], nil}}]
      }

      assert_raise ArgumentError, ~r/first_value\/1 expects exactly one argument, got 0/, fn ->
        run(query)
      end
    end

    test "an unknown/non-window function used with OVER raises a clear error" do
      query = %Query{
        source: ["employees"],
        select: [
          {:computed, "x", {:window, {:call, "string", [{:field, ["salary"]}]}, [], [], nil}}
        ]
      }

      assert_raise ArgumentError, ~r/string\(\.\.\.\) is not a valid window function/, fn ->
        run(query)
      end
    end

    test "first_value/last_value over a nil value do not raise -- selection, not reduction" do
      data =
        Map.put(@data, ["employees"], [%{"name" => "A", "department" => "x", "salary" => nil}])

      query = %Query{
        source: ["employees"],
        select: [
          {:computed, "top",
           {:window, {:call, "first_value", [{:field, ["salary"]}]}, [["department"]], [], nil}}
        ]
      }

      assert {:ok, [%{"top" => nil}]} = Executor.run(query, FakeEngine, data) |> materialize()
    end

    test "an aggregate-as-window-function over a nil value still hard-errors, reusing eval_aggregate's own message" do
      data =
        Map.put(@data, ["employees"], [%{"name" => "A", "department" => "x", "salary" => nil}])

      query = %Query{
        source: ["employees"],
        select: [
          {:computed, "s",
           {:window, {:call, "sum", [{:field, ["salary"]}]}, [["department"]], [], nil}}
        ]
      }

      assert_raise ArgumentError, ~r/encountered a nil value/, fn ->
        Executor.run(query, FakeEngine, data) |> elem(1) |> Cursor.to_list()
      end
    end

    test "an inverted/empty frame produces the same empty-aggregate answers a plain aggregate gives for zero rows" do
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "s",
           {:window, {:call, "sum", [{:field, ["salary"]}]}, [["department"]],
            [{["salary"], :asc}], {{:following, 1}, {:preceding, 1}}}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert Enum.all?(rows, &(&1["s"] == nil))
    end

    test "a window-wrapped call is not itself mistaken for a triggering aggregate call" do
      # Regression class: `expr_has_aggregate_call?` must stop recursion
      # at a `{:window, ...}` boundary, not treat the wrapped `sum` as a
      # signal to route this query into GROUP BY-style flat-aggregate
      # collapsing -- confirmed by row count, not just by not raising.
      query = %Query{
        source: ["employees"],
        select: [
          {:field, ["name"]},
          {:computed, "s", {:window, {:call, "sum", [{:field, ["salary"]}]}, [], [], nil}}
        ]
      }

      assert {:ok, rows} = run(query)
      assert length(rows) == length(@employees)
    end
  end

  describe "fetch/2 returning a lazy Enumerable.t() instead of a plain list" do
    test "a plain WHERE filter, byte-identical results whether fetch/2 returns a list or a Stream" do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert run(query) == run_via_stream(query)
      assert {:ok, [%{"name" => "Alice"}, %{"name" => "Carol"}]} = run_via_stream(query)
    end

    test "GROUP BY/HAVING/an aggregate, byte-identical results whether fetch/2 returns a list or a Stream" do
      query = %Query{
        source: ["customer_orders"],
        group_bys: [["customer_id"]],
        order_bys: [{["customer_id"], :asc}],
        select: [
          {:field, ["customer_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}}
        ]
      }

      assert run(query) == run_via_stream(query)
    end

    test "a nested SELECT (correlation), byte-identical results whether fetch/2 returns a list or a Stream" do
      query = %Query{
        source: ["customers"],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: ["customer_orders"],
            wheres: [{:cmp, :eq, ["customer_id"], {:field, ["customers", "id"]}}],
            select: [{:field, ["id"]}]
          }
        ]
      }

      assert run(query) == run_via_stream(query)
    end

    test "an unknown source still surfaces the same error" do
      query = %Query{source: ["nonexistent"], select: [{:field, ["id"]}]}
      assert run_via_stream(query) == {:error, {:query_error, {:no_such_source, ["nonexistent"]}}}
    end
  end
end
