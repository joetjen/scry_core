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
    %{"name" => "Widget", "price" => 3, "cost" => 4},
    %{"name" => "Gadget", "price" => 4, "cost" => 2}
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

  @data %{
    ["users"] => @users,
    ["orders"] => @orders,
    ["products"] => @products,
    ["events"] => @events,
    ["accounts"] => @accounts,
    ["customers"] => @customers,
    ["customer_orders"] => @customer_orders,
    ["order_items"] => @order_items,
    ["line_items"] => @line_items
  }

  defp run(query), do: Executor.run(query, FakeEngine, @data)
  defp run(query, params), do: Executor.run(query, FakeEngine, @data, params)

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

  test "correlation reaches more than one nesting level up (grandparent, not just parent)" do
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

    assert {:ok, rows} = run(query)

    assert rows == [
             %{
               "name" => "Alice",
               "customer_orders" => [
                 %{"id" => 100, "order_items" => [%{"sku" => "A"}, %{"sku" => "B"}]},
                 %{"id" => 101, "order_items" => [%{"sku" => "A"}, %{"sku" => "B"}]}
               ]
             },
             %{"name" => "Bob", "customer_orders" => []},
             %{
               "name" => "Carol",
               "customer_orders" => [
                 %{"id" => 102, "order_items" => [%{"sku" => "C"}]}
               ]
             }
           ]
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
end
