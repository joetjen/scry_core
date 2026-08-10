defmodule Scry.Core.TypeCheckTest do
  use ExUnit.Case, async: true

  alias Scry.Core.{CombinedQuery, Query, TypeCheck}

  describe "name-to-source matching" do
    test "an unmatched TYPE (name != source) is inert, not an error" do
      type_decls = %{
        "Employee" => %{
          name: "Employee",
          kind: "relational",
          fields: [{"id", {:named, "Int", nil}}]
        }
      }

      query = %Query{source: ["users"], select: [], variant: %{last: {:duration, 300}}}

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a multi-segment source is never matched against a TYPE" do
      type_decls = %{"users" => %{name: "users", kind: "relational", fields: []}}
      query = %Query{source: ["schema", "users"], select: [], variant: %{last: 1}}

      assert :ok = TypeCheck.check(query, type_decls)
    end
  end

  describe "1. category check" do
    test "a degenerate kind (relational) with non-empty variant is a hard error" do
      type_decls = %{"users" => %{name: "users", kind: "relational", fields: []}}
      query = %Query{source: ["users"], select: [], variant: %{last: {:duration, 300}}}

      assert {:error, {:kind_category_mismatch, "users", "relational", [:last]}} =
               TypeCheck.check(query, type_decls)
    end

    test "olap is degenerate too" do
      type_decls = %{"cube" => %{name: "cube", kind: "olap", fields: []}}
      query = %Query{source: ["cube"], select: [], variant: %{last: 1}}

      assert {:error, {:kind_category_mismatch, "cube", "olap", [:last]}} =
               TypeCheck.check(query, type_decls)
    end

    test "a degenerate kind with an empty variant is fine" do
      type_decls = %{"users" => %{name: "users", kind: "relational", fields: []}}
      query = %Query{source: ["users"], select: [], variant: %{}}

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a non-degenerate kind with a non-empty variant is not (yet) caught" do
      type_decls = %{"g" => %{name: "g", kind: "graph", fields: []}}
      query = %Query{source: ["g"], select: [], variant: %{last: 1}}

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "no declared kind at all is fine regardless of variant" do
      type_decls = %{"users" => %{name: "users", kind: nil, fields: []}}
      query = %Query{source: ["users"], select: [], variant: %{last: 1}}

      assert :ok = TypeCheck.check(query, type_decls)
    end
  end

  describe "2. declared-field-type / union comparison check" do
    setup do
      type_decls = %{
        "users" => %{
          name: "users",
          kind: nil,
          fields: [
            {"id", {:named, "Int", nil}},
            {"name", {:named, "String", nil}},
            {"tag", {:union, [{:named, "String", nil}, {:named, "Int", nil}]}},
            {"age", {:nullable, {:named, "Int", nil}}}
          ]
        }
      }

      {:ok, type_decls: type_decls}
    end

    test "a literal accepted by the declared scalar type is fine", %{type_decls: type_decls} do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["id"], 1}]}
      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a literal rejected by the declared scalar type is an error", %{type_decls: type_decls} do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["id"], "not an int"}]}

      assert {:error, {:type_mismatch, "users", "id", {:named, "Int", nil}, "not an int"}} =
               TypeCheck.check(query, type_decls)
    end

    test "a literal accepted by any union member is fine", %{type_decls: type_decls} do
      q1 = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["tag"], "urgent"}]}
      q2 = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["tag"], 5}]}
      assert :ok = TypeCheck.check(q1, type_decls)
      assert :ok = TypeCheck.check(q2, type_decls)
    end

    test "a literal accepted by no union member is an error", %{type_decls: type_decls} do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["tag"], true}]}

      assert {:error, {:type_mismatch, "users", "tag", _type_expr, true}} =
               TypeCheck.check(query, type_decls)
    end

    test "an undeclared field is a silent no-op", %{type_decls: type_decls} do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["unknown_field"], 1}]}
      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a field-to-field comparison is never type-mismatch-checked", %{type_decls: type_decls} do
      query = %Query{
        source: ["users"],
        select: [],
        wheres: [{:cmp, :eq, ["id"], {:field, ["name"]}}]
      }

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a literal nil against a non-nullable field is exempt (the null-check idiom)", %{
      type_decls: type_decls
    } do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["id"], nil}]}
      assert :ok = TypeCheck.check(query, type_decls)
    end
  end

  describe "3. JSON/DXN/DXNB field-access validation" do
    for type_name <- ["JSON", "DXN", "DXNB"] do
      @type_name type_name

      test "#{@type_name}<{shape}>: a dot-path into a declared field is fine" do
        type_decls = %{
          "orders" => %{
            name: "orders",
            kind: nil,
            fields: [
              {"metadata", {:named, @type_name, {:shape, [{"color", {:named, "String", nil}}]}}}
            ]
          }
        }

        query = %Query{
          source: ["orders"],
          select: [],
          wheres: [{:cmp, :eq, ["metadata", "color"], "red"}]
        }

        assert :ok = TypeCheck.check(query, type_decls)
      end

      test "#{@type_name}<{shape}>: a dot-path not in the declared shape is an error" do
        type_decls = %{
          "orders" => %{
            name: "orders",
            kind: nil,
            fields: [
              {"metadata", {:named, @type_name, {:shape, [{"color", {:named, "String", nil}}]}}}
            ]
          }
        }

        query = %Query{
          source: ["orders"],
          select: [],
          wheres: [{:cmp, :eq, ["metadata", "bogus"], "red"}]
        }

        assert {:error, {:unknown_structured_field, "metadata", "bogus"}} =
                 TypeCheck.check(query, type_decls)
      end

      test "bare #{@type_name} (no shape) accepts any dot-path, no validation at all" do
        type_decls = %{
          "orders" => %{
            name: "orders",
            kind: nil,
            fields: [{"metadata", {:named, @type_name, nil}}]
          }
        }

        query = %Query{
          source: ["orders"],
          select: [],
          wheres: [{:cmp, :eq, ["metadata", "anything"], "red"}]
        }

        assert :ok = TypeCheck.check(query, type_decls)
      end

      test "#{@type_name} in a select body item is validated too" do
        type_decls = %{
          "orders" => %{
            name: "orders",
            kind: nil,
            fields: [
              {"metadata", {:named, @type_name, {:shape, [{"color", {:named, "String", nil}}]}}}
            ]
          }
        }

        query = %Query{source: ["orders"], select: [{:field, ["metadata", "bogus"]}]}

        assert {:error, {:unknown_structured_field, "metadata", "bogus"}} =
                 TypeCheck.check(query, type_decls)
      end
    end

    test "a nested shape-within-shape dot-path is validated recursively" do
      type_decls = %{
        "orders" => %{
          name: "orders",
          kind: nil,
          fields: [
            {"metadata",
             {:named, "JSON",
              {:shape,
               [
                 {"address",
                  {:shape,
                   [
                     {"city", {:named, "String", nil}}
                   ]}}
               ]}}}
          ]
        }
      }

      ok_query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :eq, ["metadata", "address", "city"], "NYC"}]
      }

      bad_query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :eq, ["metadata", "address", "zip"], "10001"}]
      }

      assert :ok = TypeCheck.check(ok_query, type_decls)

      assert {:error, {:unknown_structured_field, "metadata", "zip"}} =
               TypeCheck.check(bad_query, type_decls)
    end

    test "the json(field).path escape hatch is never validated" do
      type_decls = %{
        "orders" => %{
          name: "orders",
          kind: nil,
          fields: [
            {"metadata", {:named, "JSON", {:shape, [{"color", {:named, "String", nil}}]}}}
          ]
        }
      }

      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :eq, {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["bogus"]}, "red"}]
      }

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a dot-path into a plain scalar-typed field is a no-op (out of scope)" do
      type_decls = %{
        "orders" => %{name: "orders", kind: nil, fields: [{"total", {:named, "Int", nil}}]}
      }

      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :eq, ["total", "cents"], 100}]
      }

      assert :ok = TypeCheck.check(query, type_decls)
    end
  end

  describe "4. flow-sensitive null-safety narrowing" do
    setup do
      type_decls = %{
        "users" => %{
          name: "users",
          kind: nil,
          fields: [
            {"id", {:named, "Int", nil}},
            {"age", {:nullable, {:named, "Int", nil}}},
            {"nickname", {:nullable, {:named, "String", nil}}}
          ]
        }
      }

      {:ok, type_decls: type_decls}
    end

    test "comparing a nullable field with no prior guard is an error", %{type_decls: type_decls} do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :gt, ["age"], 30}]}

      assert {:error, {:unguarded_null_comparison, "users", "age"}} =
               TypeCheck.check(query, type_decls)
    end

    test "comparing a non-nullable field needs no guard at all", %{type_decls: type_decls} do
      query = %Query{source: ["users"], select: [], wheres: [{:cmp, :eq, ["id"], 1}]}
      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "the classic unsafe ordering: guard after the comparison it should protect still fails",
         %{type_decls: type_decls} do
      # age > 30 AND NOT (age = nil)
      predicate =
        {:and, {:cmp, :gt, ["age"], 30}, {:not, {:cmp, :eq, ["age"], nil}}}

      query = %Query{source: ["users"], select: [], wheres: [predicate]}

      assert {:error, {:unguarded_null_comparison, "users", "age"}} =
               TypeCheck.check(query, type_decls)
    end

    test "the safe ordering: guard before the comparison it protects passes", %{
      type_decls: type_decls
    } do
      # NOT (age = nil) AND age > 30
      predicate =
        {:and, {:not, {:cmp, :eq, ["age"], nil}}, {:cmp, :gt, ["age"], 30}}

      query = %Query{source: ["users"], select: [], wheres: [predicate]}
      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "age = nil OR age > 30 is safe -- OR's own short-circuit proves age non-nil on the right",
         %{type_decls: type_decls} do
      predicate = {:or, {:cmp, :eq, ["age"], nil}, {:cmp, :gt, ["age"], 30}}
      query = %Query{source: ["users"], select: [], wheres: [predicate]}
      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "age > 30 OR age = nil is unsafe -- the comparison comes before any guard", %{
      type_decls: type_decls
    } do
      predicate = {:or, {:cmp, :gt, ["age"], 30}, {:cmp, :eq, ["age"], nil}}
      query = %Query{source: ["users"], select: [], wheres: [predicate]}

      assert {:error, {:unguarded_null_comparison, "users", "age"}} =
               TypeCheck.check(query, type_decls)
    end

    test "a guard proven in an earlier WHERE clause covers a later one in the same list", %{
      type_decls: type_decls
    } do
      query = %Query{
        source: ["users"],
        select: [],
        wheres: [{:cmp, :not_eq, ["age"], nil}, {:cmp, :gt, ["age"], 30}]
      }

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "a WHERE-side proof does not survive into HAVING's own independent walk", %{
      type_decls: type_decls
    } do
      query = %Query{
        source: ["users"],
        select: [],
        wheres: [{:cmp, :not_eq, ["age"], nil}],
        havings: [{:cmp, :gt, ["age"], 30}]
      }

      assert {:error, {:unguarded_null_comparison, "users", "age"}} =
               TypeCheck.check(query, type_decls)
    end

    test "HAVING gets its own guard, independent of WHERE", %{type_decls: type_decls} do
      query = %Query{
        source: ["users"],
        select: [],
        havings: [{:not, {:cmp, :eq, ["age"], nil}}, {:cmp, :gt, ["age"], 30}]
      }

      assert :ok = TypeCheck.check(query, type_decls)
    end

    test "an unrelated field's guard does not cover a different nullable field", %{
      type_decls: type_decls
    } do
      query = %Query{
        source: ["users"],
        select: [],
        wheres: [
          {:cmp, :not_eq, ["nickname"], nil},
          {:cmp, :gt, ["age"], 30}
        ]
      }

      assert {:error, {:unguarded_null_comparison, "users", "age"}} =
               TypeCheck.check(query, type_decls)
    end

    test "a {:param, ...} rhs is not required to be proven (unprovable, out of scope)", %{
      type_decls: type_decls
    } do
      query = %Query{
        source: ["users"],
        select: [],
        wheres: [{:cmp, :eq, ["id"], {:param, "id"}}]
      }

      assert :ok = TypeCheck.check(query, type_decls)
    end
  end

  describe "recursion into nested queries, WITH bindings, and CombinedQuery" do
    setup do
      type_decls = %{
        "users" => %{
          name: "users",
          kind: "relational",
          fields: [{"id", {:named, "Int", nil}}]
        }
      }

      {:ok, type_decls: type_decls}
    end

    test "a category-check failure inside a nested select is caught", %{type_decls: type_decls} do
      nested = %Query{source: ["users"], select: [], variant: %{last: 1}}
      top = %Query{source: ["orders"], select: [nested]}

      assert {:error, {:kind_category_mismatch, "users", "relational", [:last]}} =
               TypeCheck.check(top, type_decls)
    end

    test "a category-check failure inside a WITH binding value is caught", %{
      type_decls: type_decls
    } do
      bound = %Query{source: ["users"], select: [], variant: %{last: 1}}
      top = %Query{source: ["orders"], select: [], with_bindings: %{"u" => bound}}

      assert {:error, {:kind_category_mismatch, "users", "relational", [:last]}} =
               TypeCheck.check(top, type_decls)
    end

    test "a category-check failure on either side of a CombinedQuery is caught", %{
      type_decls: type_decls
    } do
      left = %Query{source: ["users"], select: [], variant: %{last: 1}}
      right = %Query{source: ["users"], select: []}
      combined = %CombinedQuery{op: :union, left: left, right: right, type_decls: type_decls}

      assert {:error, {:kind_category_mismatch, "users", "relational", [:last]}} =
               TypeCheck.check(combined)
    end

    test "no cross-side type-consistency checking exists for a CombinedQuery (regression)" do
      # lang_spec.md never specifies this as a requirement -- two
      # incompatible declared shapes on either side of a UNION is not
      # (and should not become, absent a documented spec requirement) an
      # error this module raises.
      type_decls = %{
        "a" => %{name: "a", kind: nil, fields: [{"id", {:named, "Int", nil}}]},
        "b" => %{name: "b", kind: nil, fields: [{"id", {:named, "String", nil}}]}
      }

      left = %Query{source: ["a"], select: [], wheres: [{:cmp, :eq, ["id"], 1}]}
      right = %Query{source: ["b"], select: [], wheres: [{:cmp, :eq, ["id"], 1}]}
      combined = %CombinedQuery{op: :union, left: left, right: right, type_decls: type_decls}

      assert {:error, {:type_mismatch, "b", "id", _type_expr, 1}} = TypeCheck.check(combined)
    end
  end

  test "check/1 reads type_decls straight off the struct" do
    type_decls = %{"users" => %{name: "users", kind: "relational", fields: []}}
    query = %Query{source: ["users"], select: [], variant: %{last: 1}, type_decls: type_decls}

    assert {:error, {:kind_category_mismatch, "users", "relational", [:last]}} =
             TypeCheck.check(query)
  end

  test "a document with no TYPE declarations at all sees zero behavior change" do
    query = %Query{
      source: ["users"],
      select: [],
      wheres: [{:cmp, :gt, ["age"], 30}],
      variant: %{last: 1}
    }

    assert :ok = TypeCheck.check(query, %{})
  end

  describe "an unresolved {:variant, ...} predicate (EP1(e), e.g. search's own SEARCH)" do
    test "is inert with no TYPE declaration at all -- the real regression this covers" do
      # Found building scry_search: every one of walk_type_check/3,
      # walk_json_check/2, and check_predicate/4 lacked a {:variant, ...}
      # clause, so parsing *any* query using SEARCH crashed with a raw
      # FunctionClauseError here, unconditionally -- not gated behind a
      # TYPE declaration existing at all (this test has none).
      query = %Query{
        source: ["articles"],
        select: [{:field, ["title"]}],
        wheres: [{:variant, {:search, ["content"], "machine learning"}}]
      }

      assert :ok = TypeCheck.check(query, %{})
    end

    test "is inert nested inside AND/OR/NOT too" do
      query = %Query{
        source: ["articles"],
        select: [{:field, ["title"]}],
        wheres: [
          {:and, {:cmp, :eq, ["category"], "research"},
           {:not, {:variant, {:search, ["content"], "ml"}}}}
        ]
      }

      assert :ok = TypeCheck.check(query, %{})
    end

    test "is inert even with a real TYPE declaration for the same source" do
      type_decls = %{
        "articles" => %{
          name: "articles",
          kind: "relational",
          fields: [{"title", {:named, "String", nil}}]
        }
      }

      query = %Query{
        source: ["articles"],
        select: [{:field, ["title"]}],
        wheres: [{:variant, {:search, ["content"], "ml"}}],
        type_decls: type_decls
      }

      assert :ok = TypeCheck.check(query)
    end
  end
end
