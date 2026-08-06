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

  test "group by a single field", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders GROUP BY status { status }))
    assert q.group_bys == [["status"]]
  end

  test "group by multiple, dotted fields", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT orders GROUP BY customer.region, status { status }))

    assert q.group_bys == [["customer", "region"], ["status"]]
  end

  test "having, independent of group by", %{grammar: g} do
    # `having` doesn't require an aggregate expression to *parse* yet --
    # there's no such thing as an aggregate expression in the grammar at
    # all yet (priv/grammar.aether's own header), so this only proves
    # the clause itself parses and reaches Query.havings, not the
    # "having requires an aggregate" compile-time check lang_spec.md §5.2
    # describes (also not implemented yet, same reason).
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders HAVING total > 100 { id }))
    assert q.havings == [{:cmp, :gt, ["total"], 100}]
  end

  test "distinct is absent by default and present when written", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }))
    refute q.distinct

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT users DISTINCT { name }))
    assert q2.distinct
  end

  test "order by, default direction is ascending", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users ORDER BY age { name }))
    assert q.order_bys == [{["age"], :asc}]
  end

  test "order by, explicit desc/asc, multiple fields, case-insensitive", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users ORDER BY age desc, name ASC { name }))

    assert q.order_bys == [{["age"], :desc}, {["name"], :asc}]
  end

  test "limit alone", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users LIMIT 10 { name }))
    assert q.limit == 10
    assert q.offset == nil
  end

  test "limit with offset", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users LIMIT 10 OFFSET 20 { name }))
    assert q.limit == 10
    assert q.offset == 20
  end

  test "the full header-modifier chain together, in its required fixed order", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(SELECT orders WHERE total > 50 GROUP BY status DISTINCT
                  ORDER BY status LIMIT 5 OFFSET 1 REQUIRED { status })
             )

    assert q.wheres == [{:cmp, :gt, ["total"], 50}]
    assert q.group_bys == [["status"]]
    assert q.distinct
    assert q.order_bys == [{["status"], :asc}]
    assert q.limit == 5
    assert q.offset == 1
    assert q.required
  end

  test "REQUIRED is absent by default and present when written", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders { id }))
    refute q.required

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT orders REQUIRED { id }))
    assert q2.required
  end

  test "REQUIRED on a nested SELECT, correlated to the outer row via a field-to-field comparison",
       %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(SELECT users { name, SELECT orders WHERE user_id = users.id REQUIRED { id } })
             )

    assert [{:field, ["name"]}, %Query{} = nested] = q.select
    assert nested.source == ["orders"]
    assert nested.wheres == [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}]
    assert nested.required
  end

  test "the fixed modifier order is enforced -- writing modifiers out of order fails to parse", %{
    grammar: g
  } do
    assert {:error, _} = run(g, ~s(SELECT users LIMIT 5 WHERE age > 30 { name }))
    assert {:error, _} = run(g, ~s(SELECT users ORDER BY age DISTINCT { name }))
    assert {:error, _} = run(g, ~s(SELECT users REQUIRED LIMIT 5 { name }))
  end

  test "double-quoted string escapes: quote, backslash, newline, tab", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~S(SELECT users WHERE bio = "line1\nline2\ttabbed \"quoted\" back\\slash" { name })
             )

    assert q.wheres == [
             {:cmp, :eq, ["bio"], "line1\nline2\ttabbed \"quoted\" back\\slash"}
           ]
  end

  test "a \\uXXXX unicode escape", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE name = "caf\u00e9" { name }))
    assert q.wheres == [{:cmp, :eq, ["name"], "café"}]
  end

  test "single-quoted strings, useful for content containing an unescaped double-quote", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE quote = 'she said "hi"' { name }))
    assert q.wheres == [{:cmp, :eq, ["quote"], ~s(she said "hi")}]
  end

  test "single-quoted strings support the same escapes, including an escaped single-quote", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE name = 'it\'s "quoted"' { name }))
    assert q.wheres == [{:cmp, :eq, ["name"], ~s(it's "quoted")}]
  end

  test "an unrecognized escape passes the backslash through literally", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE path = "C:\Users" { name }))
    assert q.wheres == [{:cmp, :eq, ["path"], "C:\\Users"}]
  end

  test "a backtick-escaped identifier lets a keyword-colliding name be used as a source", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT `select` { name }))
    assert q.source == ["select"]
  end

  test "a backtick-escaped identifier as a projected field", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { `where` }))
    assert q.select == [{:field, ["where"]}]
  end

  test "a backtick-escaped identifier in a dotted path, mixed with a plain segment", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT `order`.total { name }))
    assert q.source == ["order", "total"]
  end

  test "the escaped text is preserved as-is, not downcased or otherwise normalized", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { `Where` }))
    assert q.select == [{:field, ["Where"]}]
  end

  test "an unescaped keyword-colliding name still can't be used as a plain field name", %{
    grammar: g
  } do
    assert {:error, _} = run(g, ~s(SELECT select { name }))
  end

  test "a list literal as a comparison value, not just inside in [...]", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE tags = ["a", "b"] { name }))
    assert q.wheres == [{:cmp, :eq, ["tags"], ["a", "b"]}]
  end

  test "an empty list literal", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE tags = [] { name }))
    assert q.wheres == [{:cmp, :eq, ["tags"], []}]
  end

  test "a nested list literal", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE matrix = [[1, 2], [3, 4]] { name }))

    assert q.wheres == [{:cmp, :eq, ["matrix"], [[1, 2], [3, 4]]}]
  end

  test "a list literal of mixed literal kinds", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE mixed = [1, "two", 3.5, nil, true] { name }))

    assert q.wheres == [{:cmp, :eq, ["mixed"], [1, "two", Rational.new(7, 2), nil, true]}]
  end

  test "in [...] still works, now built on the same list rule", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE status in ["active", "pending"] { name }))

    assert q.wheres == [{:in, ["status"], ["active", "pending"]}]

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT users WHERE status in [] { name }))
    assert q2.wheres == [{:in, ["status"], []}]
  end

  test "an atom literal, tagged rather than a real Elixir atom", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE status = :active { name }))
    assert q.wheres == [{:cmp, :eq, ["status"], {:atom, "active"}}]

    # Not `:active` -- see ScryCore.Actions' own handle_token(:ATOM, ...)
    # for why turning arbitrary query text into real Elixir atoms would
    # be a DoS vector, not just a style choice.
    refute match?({:cmp, :eq, ["status"], :active}, hd(q.wheres))
  end

  test "an atom literal's case is preserved as-is, unlike a keyword's reclassification", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE status = :Active { name }))
    assert q.wheres == [{:cmp, :eq, ["status"], {:atom, "Active"}}]
  end

  test "atom literals inside a list literal", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE status in [:active, :pending] { name }))

    assert q.wheres == [{:in, ["status"], [{:atom, "active"}, {:atom, "pending"}]}]
  end

  test "a multiline string, embedded newline preserved verbatim", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE bio = """line one
line two""" { name }))

    assert q.wheres == [{:cmp, :eq, ["bio"], "line one\nline two"}]
  end

  test "a multiline string containing a lone double-quote, unescaped", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE bio = """she said "hi" once""" { name }))

    assert q.wheres == [{:cmp, :eq, ["bio"], ~s(she said "hi" once)}]
  end

  test "an empty multiline string", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE bio = """""" { name }))
    assert q.wheres == [{:cmp, :eq, ["bio"], ""}]
  end

  test "a multiline string honors the same escapes as single-line strings", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE bio = """tab\there""" { name }))
    assert q.wheres == [{:cmp, :eq, ["bio"], "tab\there"}]
  end

  test "a full ISO 8601 timestamp with a Z offset parses to a real DateTime", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT events WHERE at = 2026-01-01T14:00:00Z { name }))

    assert q.wheres == [{:cmp, :eq, ["at"], ~U[2026-01-01 14:00:00Z]}]
  end

  test "a timestamp with a numeric UTC offset is normalized to UTC", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT events WHERE at = 2026-01-01T14:00:00+02:00 { name }))

    assert q.wheres == [{:cmp, :eq, ["at"], ~U[2026-01-01 12:00:00Z]}]
  end

  test "a timestamp with no offset parses to a NaiveDateTime", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT events WHERE at = 2026-01-01T14:00:00 { name }))

    assert q.wheres == [{:cmp, :eq, ["at"], ~N[2026-01-01 14:00:00]}]
  end

  test "a bare date (no time part) parses to a Date", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT events WHERE day = 2026-01-01 { name }))
    assert q.wheres == [{:cmp, :eq, ["day"], ~D[2026-01-01]}]
  end

  test "a timestamp with fractional seconds", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT events WHERE at = 2026-01-01T14:00:00.500Z { name }))

    assert q.wheres == [{:cmp, :eq, ["at"], ~U[2026-01-01 14:00:00.500Z]}]
  end

  test "an invalid calendar date surfaces as a parse error, not a raise", %{grammar: g} do
    assert {:error, _} = run(g, ~s(SELECT events WHERE day = 2026-02-30 { name }))
  end

  # Asserted on `.source` (the pattern text), not `==` against the whole
  # `%Regex{}` -- two separately-compiled regexes from *identical*
  # source aren't `==` (their `:re_pattern` field, the compiled NIF
  # resource, differs even then), confirmed empirically after these
  # tests failed on a first pass despite the two sides printing
  # identically. Real for Executor too, in principle, but not a fix it
  # needs: `~` is the only operator lang_spec.md §5.9 pairs with a
  # regex, and it dispatches straight to `Regex.match?/2`, never `==`.

  test "a regex sigil literal, matched against a field with ~", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE email ~ @r/^[a-z]+@/ { name }))
    assert [{:cmp, :match, ["email"], %Regex{source: "^[a-z]+@"}}] = q.wheres
  end

  test "a sigil escaping its own delimiter", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE path ~ @r/a\/b/ { name }))
    assert [{:cmp, :match, ["path"], %Regex{source: "a/b"}}] = q.wheres
  end

  test "a regex escape (\\d) inside a sigil reaches the regex engine untouched", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE code ~ @r/\d+/ { name }))
    assert [{:cmp, :match, ["code"], %Regex{source: "\\d+"}}] = q.wheres
  end

  test "an unsupported sigil tag surfaces as a parse error", %{grammar: g} do
    assert {:error, _} = run(g, ~s(SELECT users WHERE name ~ @x/foo/ { name }))
  end

  test "a malformed regex sigil surfaces as a parse error, not a raise", %{grammar: g} do
    assert {:error, _} = run(g, ~s(SELECT users WHERE name ~ @r/[a-z/ { name }))
  end

  test "a field-to-field comparison (right-hand side is a path, not a literal)", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT products WHERE price > cost { name }))
    assert q.wheres == [{:cmp, :gt, ["price"], {:field, ["cost"]}}]
  end

  test "a field-to-field comparison with a multi-segment right-hand path", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT orders WHERE user_id = users.id { id }))

    assert q.wheres == [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}]
  end

  test "an external parameter parses to a {:param, name} placeholder, not a value", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE age > $minAge { name }))
    assert q.wheres == [{:cmp, :gt, ["age"], {:param, "minAge"}}]
  end

  test "an external parameter inside an in [...] list", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE status in [$a, $b] { name }))
    assert q.wheres == [{:in, ["status"], [{:param, "a"}, {:param, "b"}]}]
  end

  test "a plain field body item has no condition, unchanged", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }))
    assert q.select == [{:field, ["name"]}]
  end

  test "a conditionally-included field body item (IF $param)", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name, email IF $includeEmail }))
    assert q.select == [{:field, ["name"]}, {:field, ["email"], {:param, "includeEmail"}}]
  end
end
