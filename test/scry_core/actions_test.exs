defmodule ScryCore.ActionsTest do
  use ExUnit.Case, async: true

  alias ScryCore.{Query, Rational}

  setup_all do
    # No stub needed for select_ep1a -- core's own grammar is complete
    # and analyzes on its own now (ScryCore.GrammarComposeTest covers
    # why: an unfilled extension point needs a real "always fails"
    # default, not a dangling reference, so a zero-kind build still
    # compiles). None of these core-only tests exercise the extension
    # point for real, since no real kind fragment exists yet to merge
    # in properly (impl_spec.md §4).
    {:ok, analyzed} = ScryCore.Grammar.compile()
    %{grammar: analyzed}
  end

  defp run(grammar, query), do: Grammar.VM.run(grammar, query, ScryCore.Actions, nil)

  test "a bare select with no where clause", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }))
    assert q.source == ["users"]
    assert q.select == [{:field, ["name"]}]
    assert q.wheres == []
  end

  test "multiple projected fields, dotted source", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders.line_items { name, email }))
    assert q.source == ["orders", "line_items"]
    assert q.select == [{:field, ["name"]}, {:field, ["email"]}]
  end

  test "a nested SELECT as a body item", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(SELECT users { name, SELECT orders WHERE total > 50 { id, total } })
             )

    assert q.select == [
             {:field, ["name"]},
             %Query{
               source: ["orders"],
               wheres: [{:cmp, :gt, ["total"], 50}],
               select: [{:field, ["id"]}, {:field, ["total"]}]
             }
           ]
  end

  test "a where clause with a numeric comparison", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE age > 30 { name }))
    assert q.wheres == [{:cmp, :gt, ["age"], 30}]
  end

  test "a where clause with a string comparison, not=, and boolean literals", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE status not= "inactive" { name }))
    assert q.wheres == [{:cmp, :not_eq, ["status"], "inactive"}]

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT users WHERE active = true { name }))
    assert q2.wheres == [{:cmp, :eq, ["active"], true}]

    assert {:ok, %Query{} = q3} = run(g, ~s(SELECT users WHERE deleted_at = nil { name }))
    assert q3.wheres == [{:cmp, :eq, ["deleted_at"], nil}]
  end

  test "and/or/not combine correctly, and/or left-associative", %{grammar: g} do
    assert {:ok, %Query{wheres: [pred]}} =
             run(g, ~s(SELECT users WHERE age > 30 AND age < 65 { name }))

    assert pred == {:and, {:cmp, :gt, ["age"], 30}, {:cmp, :lt, ["age"], 65}}

    assert {:ok, %Query{wheres: [or_pred]}} =
             run(g, ~s(SELECT users WHERE age < 18 OR age > 65 { name }))

    assert or_pred == {:or, {:cmp, :lt, ["age"], 18}, {:cmp, :gt, ["age"], 65}}

    assert {:ok, %Query{wheres: [not_pred]}} =
             run(g, ~s(SELECT users WHERE NOT age > 30 { name }))

    assert not_pred == {:not, {:cmp, :gt, ["age"], 30}}
  end

  test "in [...] with an empty and a non-empty list", %{grammar: g} do
    assert {:ok, %Query{wheres: [empty_pred]}} =
             run(g, ~s(SELECT users WHERE status in [] { name }))

    assert empty_pred == {:in, ["status"], []}

    assert {:ok, %Query{wheres: [pred]}} =
             run(g, ~s(SELECT users WHERE status in ["active", "pending"] { name }))

    assert pred == {:in, ["status"], ["active", "pending"]}
  end

  test "keywords are genuinely case-insensitive end to end", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(select users where age > 30 and not status = "x" { name }))

    assert q.wheres == [{:and, {:cmp, :gt, ["age"], 30}, {:not, {:cmp, :eq, ["status"], "x"}}}]
  end

  test "a decimal literal parses to its exact rational value", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT products WHERE price = 3.14 { name }))
    assert q.wheres == [{:cmp, :eq, ["price"], Rational.new(157, 50)}]
  end

  test "a decimal literal whose value is a whole number collapses to a plain integer", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT products WHERE price = 4.0 { name }))
    assert q.wheres == [{:cmp, :eq, ["price"], 4}]
  end

  test "a 2/3-shaped rational literal", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT products WHERE ratio > 2/3 { name }))
    assert q.wheres == [{:cmp, :gt, ["ratio"], Rational.new(2, 3)}]
  end

  test "a rational literal that reduces to a whole number collapses to a plain integer", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT products WHERE qty = 6/3 { name }))
    assert q.wheres == [{:cmp, :eq, ["qty"], 2}]
  end

  test "hex/octal/binary radix literals parse as plain integers, not a distinct type", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT flags WHERE mask = 0x1F { name }))
    assert q.wheres == [{:cmp, :eq, ["mask"], 31}]

    assert {:ok, %Query{} = q2} = run(g, ~s(select flags where mask = 0X1f { name }))
    assert q2.wheres == [{:cmp, :eq, ["mask"], 31}]

    assert {:ok, %Query{} = q3} = run(g, ~s(SELECT flags WHERE mask = 0o17 { name }))
    assert q3.wheres == [{:cmp, :eq, ["mask"], 15}]

    assert {:ok, %Query{} = q4} = run(g, ~s(SELECT flags WHERE mask = 0b101 { name }))
    assert q4.wheres == [{:cmp, :eq, ["mask"], 5}]
  end
end
