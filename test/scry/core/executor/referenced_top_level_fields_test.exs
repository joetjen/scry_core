defmodule Scry.Core.Executor.ReferencedTopLevelFieldsTest do
  @moduledoc """
  `Scry.Core.Executor.referenced_top_level_fields/2` -- the static
  column-reference enumerator behind `EngineBehaviour.fetch/4`'s
  `opts.columns` hint. Exhaustive, one test per `predicate()`/`expr()`/
  `body_item()` shape, mirroring `resolve_predicate_lhs/4`/
  `resolve_rhs/4`'s own clause sets one-for-one (`Scry.Core.Executor`'s
  own moduledoc has the full design reasoning) -- plus the two
  conservative bail-outs (`nested SELECT`, window function) and the
  single-segment-vs-ancestor-name rule that an earlier draft of this
  feature got wrong (a design review caught it before it shipped: a
  bare single-segment path is *never* excluded by an ancestor-name
  match, since `get_path/3`'s own single-segment clause never consults
  `scope` at all).

  A wrongly-collected (too-narrow) result here doesn't just fail a
  test -- it's the exact failure mode that would let a real query
  silently return `nil` for a genuinely-needed, wrongly-pruned column
  in production, so every shape gets its own direct assertion rather
  than a handful of representative examples.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Executor, Query}

  defp fields(query, ancestor_names \\ MapSet.new()) do
    Executor.referenced_top_level_fields(query, ancestor_names)
  end

  defp ok(columns), do: {:ok, MapSet.new(columns)}

  describe "wheres -- predicate() shapes" do
    test "bare :cmp with a field lhs (path) and literal rhs" do
      query = %Query{wheres: [{:cmp, :eq, ["status"], "active"}]}
      assert fields(query) == ok(["status"])
    end

    test ":cmp with a {:field, path} rhs" do
      query = %Query{wheres: [{:cmp, :eq, ["a"], {:field, ["b"]}}]}
      assert fields(query) == ok(["a", "b"])
    end

    test ":cmp with a {:param, name} rhs contributes no extra column" do
      query = %Query{wheres: [{:cmp, :eq, ["status"], {:param, "wanted"}}]}
      assert fields(query) == ok(["status"])
    end

    test ":cmp with literal nil rhs (the null-check idiom)" do
      query = %Query{wheres: [{:cmp, :eq, ["age"], nil}]}
      assert fields(query) == ok(["age"])
    end

    test ":cmp lhs as {:call, name, args}" do
      query = %Query{wheres: [{:cmp, :eq, {:call, "string", [{:field, ["id"]}]}, "1"}]}
      assert fields(query) == ok(["id"])
    end

    test ":cmp lhs as {:dot, base, path} -- json(<field>).path" do
      query = %Query{
        wheres: [
          {:cmp, :eq, {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["color"]}, "red"}
        ]
      }

      assert fields(query) == ok(["metadata"])
    end

    test ":in with a literal list of values" do
      query = %Query{wheres: [{:in, ["status"], ["active", "pending"]}]}
      assert fields(query) == ok(["status"])
    end

    test ":in with a literal list containing a {:param, name} element" do
      query = %Query{wheres: [{:in, ["status"], [{:param, "wanted"}]}]}
      assert fields(query) == ok(["status"])
    end

    test ":in with a single computed-list expr (e.g. json(metadata).tags)" do
      query = %Query{
        wheres: [{:in, ["tag"], {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["tags"]}}]
      }

      assert fields(query) == ok(["tag", "metadata"])
    end

    test ":in with a {:literal, value} lhs (the literal-on-the-left shape)" do
      query = %Query{wheres: [{:in, {:literal, "urgent"}, {:field, ["tags"]}}]}
      assert fields(query) == ok(["tags"])
    end

    test ":and/:or/:not compose recursively" do
      query = %Query{
        wheres: [
          {:and, {:cmp, :eq, ["a"], 1},
           {:or, {:cmp, :eq, ["b"], 2}, {:not, {:cmp, :eq, ["c"], 3}}}}
        ]
      }

      assert fields(query) == ok(["a", "b", "c"])
    end

    test "an unrecognized predicate shape bails to :unknown, never silently drops it" do
      query = %Query{wheres: [:bogus]}
      assert fields(query) == :unknown
    end
  end

  describe "havings -- same predicate() shapes, reused as-is" do
    test "an aggregate call in a HAVING predicate still collects its own field argument" do
      query = %Query{havings: [{:cmp, :gt, {:call, "sum", [{:field, ["total"]}]}, 100}]}
      assert fields(query) == ok(["total"])
    end
  end

  describe "group_bys / order_bys -- raw path lists, not {:field, ...}-wrapped" do
    test "group_bys" do
      query = %Query{group_bys: [["status"], ["region"]]}
      assert fields(query) == ok(["status", "region"])
    end

    test "order_bys" do
      query = %Query{order_bys: [{["age"], :asc}, {["name"], :desc}]}
      assert fields(query) == ok(["age", "name"])
    end
  end

  describe "select -- body_item() shapes" do
    test "a bare {:field, path}" do
      query = %Query{select: [{:field, ["name"]}]}
      assert fields(query) == ok(["name"])
    end

    test "a conditional {:field, path, {:param, name}} select item" do
      query = %Query{select: [{:field, ["name"], {:param, "include_name"}}]}
      assert fields(query) == ok(["name"])
    end

    test "{:computed, alias, expr} recurses into expr" do
      query = %Query{select: [{:computed, "n", {:field, ["name"]}}]}
      assert fields(query) == ok(["name"])
    end

    test "{:variant, term} contributes nothing (no execution semantics, not :unknown)" do
      query = %Query{select: [{:variant, %{fake: true}}]}
      assert fields(query) == ok([])
    end

    test "a nested %Query{} in select bails to :unknown" do
      query = %Query{
        select: [{:field, ["id"]}, %Query{source: ["orders"], select: [{:field, ["total"]}]}]
      }

      assert fields(query) == :unknown
    end

    test "an unrecognized body item shape bails to :unknown" do
      query = %Query{select: [{:totally_unrecognized, "x"}]}
      assert fields(query) == :unknown
    end
  end

  describe "expr() shapes, reached via {:computed, ...}" do
    test "{:arith, op, l, r} collects both operands" do
      query = %Query{select: [{:computed, "t", {:arith, :add, {:field, ["a"]}, {:field, ["b"]}}}]}
      assert fields(query) == ok(["a", "b"])
    end

    test "{:when, clauses, else_expr} collects every clause's predicate and expr, plus else" do
      query = %Query{
        select: [
          {:computed, "x",
           {:when, [{{:cmp, :eq, ["flag"], true}, {:field, ["a"]}}], {:field, ["b"]}}}
        ]
      }

      assert fields(query) == ok(["flag", "a", "b"])
    end

    test "{:call, name, args} recurses into every argument" do
      query = %Query{select: [{:computed, "t", {:call, "string", [{:field, ["id"]}]}}]}
      assert fields(query) == ok(["id"])
    end

    test "{:distinct, expr} (count(distinct ...)) recurses into expr" do
      query = %Query{
        select: [{:computed, "n", {:call, "count", [{:distinct, {:field, ["id"]}}]}}]
      }

      assert fields(query) == ok(["id"])
    end

    test "{:dot, base, path} recurses into base only -- path is never a field ref" do
      query = %Query{
        select: [{:computed, "c", {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["color"]}}]
      }

      assert fields(query) == ok(["metadata"])
    end

    test "a plain literal leaf (number, string, boolean) contributes nothing" do
      query = %Query{select: [{:computed, "n", 42}]}
      assert fields(query) == ok([])
    end

    test "a window function anywhere in select bails to :unknown" do
      query = %Query{
        select: [
          {:computed, "r",
           {:window, {:call, "row_number", []}, [["department"]], [{["salary"], :desc}], nil}}
        ]
      }

      assert fields(query) == :unknown
    end
  end

  describe "ancestor-name exclusion -- the corrected, review-caught rule" do
    test "a multi-segment path whose first segment matches an ancestor is excluded (not this query's own column)" do
      query = %Query{wheres: [{:cmp, :eq, ["users", "id"], 1}]}
      assert fields(query, MapSet.new(["users"])) == ok([])
    end

    test "a multi-segment path whose first segment does NOT match any ancestor is this query's own column" do
      query = %Query{wheres: [{:cmp, :eq, ["address", "city"], "NYC"}]}
      assert fields(query, MapSet.new(["users"])) == ok(["address"])
    end

    test "a single-segment path is ALWAYS this query's own column, even if it names an ancestor" do
      query = %Query{select: [{:field, ["orders"]}]}
      assert fields(query, MapSet.new(["orders"])) == ok(["orders"])
    end

    test "no ancestors at all -- every path counts as this query's own column" do
      query = %Query{wheres: [{:cmp, :eq, ["a", "b"], 1}]}
      assert fields(query, MapSet.new()) == ok(["a"])
    end
  end

  describe "everything composed together in one realistic query" do
    test "wheres + group_bys + havings + order_bys + select all contribute" do
      query = %Query{
        wheres: [{:cmp, :eq, ["status"], "inactive"}],
        group_bys: [["region"]],
        havings: [{:cmp, :gt, {:call, "count", [{:field, ["id"]}]}, 5}],
        order_bys: [{["region"], :asc}],
        select: [{:field, ["region"]}, {:computed, "n", {:call, "count", [{:field, ["id"]}]}}]
      }

      assert fields(query) == ok(["status", "region", "id"])
    end
  end
end
