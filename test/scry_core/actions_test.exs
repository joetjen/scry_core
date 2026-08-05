defmodule ScryCore.ActionsTest do
  use ExUnit.Case, async: true

  alias ScryCore.Query

  @core_source File.read!("priv/grammar.aether")

  setup_all do
    # No stub needed for select_ep1a -- core's own grammar is complete
    # and analyzes on its own now (ScryCore.GrammarComposeTest covers
    # why: an unfilled extension point needs a real "always fails"
    # default, not a dangling reference, so a zero-kind build still
    # compiles). None of these core-only tests exercise the extension
    # point for real, since no real kind fragment exists yet to merge
    # in properly (impl_spec.md §4).
    {:ok, core} = Aether.Parser.parse(@core_source, "priv/grammar.aether")
    {:ok, analyzed} = Grammar.Analysis.run(core)
    %{grammar: analyzed}
  end

  defp run(grammar, query), do: Grammar.VM.run(grammar, query, ScryCore.Actions, nil)

  test "a bare select with no where clause", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }))
    assert q.source == ["users"]
    assert q.select == [["name"]]
    assert q.wheres == []
  end

  test "multiple projected fields, dotted source", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders.line_items { name, email }))
    assert q.source == ["orders", "line_items"]
    assert q.select == [["name"], ["email"]]
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
end
