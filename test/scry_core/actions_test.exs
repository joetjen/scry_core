defmodule ScryCore.ActionsTest do
  use ExUnit.Case, async: true

  alias ScryCore.{CombinedQuery, Query, Rational}

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

  test "duration literals enter the exact-rational tower, canonical unit seconds", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT metrics WHERE age > 1h { name }))
    assert q.wheres == [{:cmp, :gt, ["age"], 3600}]

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT metrics WHERE age > 5m { name }))
    assert q2.wheres == [{:cmp, :gt, ["age"], 300}]

    assert {:ok, %Query{} = q3} = run(g, ~s(SELECT metrics WHERE age > 2d { name }))
    assert q3.wheres == [{:cmp, :gt, ["age"], 172_800}]

    assert {:ok, %Query{} = q4} = run(g, ~s(SELECT metrics WHERE age > 1ns { name }))
    assert q4.wheres == [{:cmp, :gt, ["age"], Rational.new(1, 1_000_000_000)}]
  end

  test "a duration literal with a decimal magnitude stays exact", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT metrics WHERE age > 1.5h { name }))
    assert q.wheres == [{:cmp, :gt, ["age"], 5400}]

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT metrics WHERE latency > 500ms { name }))
    assert q2.wheres == [{:cmp, :gt, ["latency"], Rational.new(1, 2)}]
  end

  test "byte-size literals enter the exact-rational tower, canonical unit bytes", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT metrics WHERE size > 10MB { name }))
    assert q.wheres == [{:cmp, :gt, ["size"], 10_000_000}]

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT metrics WHERE size > 1KB { name }))
    assert q2.wheres == [{:cmp, :gt, ["size"], 1_000}]

    assert {:ok, %Query{} = q3} = run(g, ~s(SELECT metrics WHERE size > 1PB { name }))
    assert q3.wheres == [{:cmp, :gt, ["size"], 1_000_000_000_000_000}]
  end

  test "binary (IEC) byte-size units are distinct from decimal ones, not an alias", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT metrics WHERE size > 10MiB { name }))
    assert q.wheres == [{:cmp, :gt, ["size"], 10 * 1024 * 1024}]

    assert {:ok, %Query{} = q2} = run(g, ~s(SELECT metrics WHERE size > 1PiB { name }))
    assert q2.wheres == [{:cmp, :gt, ["size"], 1024 * 1024 * 1024 * 1024 * 1024}]
  end

  test "duration/byte-size unit suffixes are case-sensitive, not folded like keywords", %{
    grammar: g
  } do
    # Bare "M" (no "B") and wrong-case "MS" are neither a valid duration
    # nor a valid byte size (priv/grammar.aether's own DURATION/
    # BYTE_SIZE comment) -- both fail to parse rather than silently
    # matching the wrong unit.
    assert {:error, _} = run(g, ~s(SELECT metrics WHERE size > 5M { name }))
    assert {:error, _} = run(g, ~s(SELECT metrics WHERE latency > 5MS { name }))
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

  test "a sigil with a delimiter other than /, letting a / appear in the pattern unescaped", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} =
             run(g, ~S(SELECT users WHERE path ~ @r|^/usr/local/.*| { name }))

    assert [{:cmp, :match, ["path"], %Regex{source: "^/usr/local/.*"}}] = q.wheres
  end

  test "a # delimiter, another arbitrary choice", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users WHERE name ~ @r#^A.*# { name }))
    assert [{:cmp, :match, ["name"], %Regex{source: "^A.*"}}] = q.wheres
  end

  test "a non-/ sigil still escapes its own delimiter the same way", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S(SELECT users WHERE path ~ @r|a\|b| { name }))
    assert [{:cmp, :match, ["path"], %Regex{source: "a|b"}}] = q.wheres
  end

  test "an unterminated sigil with a non-/ delimiter is still a parse error, not a raise", %{
    grammar: g
  } do
    assert {:error, _} = run(g, ~s(SELECT users WHERE name ~ @r|unterminated { name }))
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

  test "a bare identifier no longer absorbs a hyphen -- not a valid identifier character", %{
    grammar: g
  } do
    assert {:error, _} = run(g, ~s(SELECT users { some-field }))
  end

  test "a computed field: alias: expression, the worked example from lang_spec.md §9", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders { subtotal: price * quantity }))

    assert q.select == [
             {:computed, "subtotal", {:arith, :mul, {:field, ["price"]}, {:field, ["quantity"]}}}
           ]
  end

  test "arithmetic operator precedence: * binds tighter than +", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT t { x: 2 + 3 * 4 }))
    assert q.select == [{:computed, "x", {:arith, :add, 2, {:arith, :mul, 3, 4}}}]
  end

  test "parentheses override precedence", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~S[SELECT t { x: (2 + 3) * 4 }])
    assert q.select == [{:computed, "x", {:arith, :mul, {:arith, :add, 2, 3}, 4}}]
  end

  test "additive chains are left-associative", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT t { x: 1 + 2 - 3 }))
    assert q.select == [{:computed, "x", {:arith, :sub, {:arith, :add, 1, 2}, 3}}]
  end

  test "** is right-associative", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT t { x: 2 ** 3 ** 2 }))
    assert q.select == [{:computed, "x", {:arith, :pow, 2, {:arith, :pow, 3, 2}}}]
  end

  test "an aliased plain field (no arithmetic) is still a valid expression", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders { total: price }))
    assert q.select == [{:computed, "total", {:field, ["price"]}}]
  end

  test "a computed field can mix a param and a literal", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders { discounted: price - $discount }))

    assert q.select == [
             {:computed, "discounted", {:arith, :sub, {:field, ["price"]}, {:param, "discount"}}}
           ]
  end

  test "a plain field body item is unaffected by computed-field support", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT orders { id, subtotal: price * quantity }))

    assert q.select == [
             {:field, ["id"]},
             {:computed, "subtotal", {:arith, :mul, {:field, ["price"]}, {:field, ["quantity"]}}}
           ]
  end

  test "no space after the alias colon reads as an atom, not alias+expression -- a real, documented lexical constraint",
       %{grammar: g} do
    # Confirmed empirically (scratch grammar) before documenting: `:`
    # immediately followed by an identifier character always loses to
    # ATOM's longer maximal-munch match. `subtotal:price` therefore
    # parses as two adjacent things, not `subtotal: price` -- this
    # specific case fails outright since two bare literals in a row
    # aren't valid body-list syntax either.
    assert {:error, _} = run(g, ~s(SELECT orders { subtotal:price }))
  end

  test "a WHEN/THEN/ELSE conditional expression, single clause", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users { tier: WHEN age > 65 THEN "senior" ELSE "other" }))

    assert q.select == [
             {:computed, "tier", {:when, [{{:cmp, :gt, ["age"], 65}, "senior"}], "other"}}
           ]
  end

  test "WHEN/THEN/ELSE with multiple clauses, evaluated in order", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(SELECT users {
                    tier: WHEN age > 65 THEN "senior" WHEN age > 18 THEN "adult" ELSE "minor"
                  })
             )

    assert q.select == [
             {:computed, "tier",
              {:when,
               [
                 {{:cmp, :gt, ["age"], 65}, "senior"},
                 {{:cmp, :gt, ["age"], 18}, "adult"}
               ], "minor"}}
           ]
  end

  test "ELSE is mandatory -- WHEN/THEN with no ELSE fails to parse", %{grammar: g} do
    assert {:error, _} = run(g, ~s(SELECT users { tier: WHEN age > 65 THEN "senior" }))
  end

  test "a WHEN condition can use full predicate syntax, same as WHERE", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(SELECT users { x: WHEN age > 18 AND status = "active" THEN 1 ELSE 0 })
             )

    assert q.select == [
             {:computed, "x",
              {:when, [{{:and, {:cmp, :gt, ["age"], 18}, {:cmp, :eq, ["status"], "active"}}, 1}],
               0}}
           ]
  end

  test "WHEN/THEN/ELSE composes with arithmetic (nested inside a parenthesized expression)", %{
    grammar: g
  } do
    # No "END" keyword -- lang_spec §5.6's own grammar has none; the
    # closing paren (from the *outer* parenthesized-expression
    # alternative) is what naturally terminates ELSE's own expression,
    # since nothing after "1"/"2" extends the additive/multiplicative
    # chain further.
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders { total: price * (WHEN vip = true THEN 1 ELSE 2) }])

    assert q.select == [
             {:computed, "total",
              {:arith, :mul, {:field, ["price"]}, {:when, [{{:cmp, :eq, ["vip"], true}, 1}], 2}}}
           ]
  end

  test "a query with no top-level FRAGMENT still parses through the document root unchanged", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }))
    assert q.select == [{:field, ["name"]}]
  end

  test "FRAGMENT + ...spread, the worked example from lang_spec.md §9", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(FRAGMENT userSummary { id, name } SELECT users { ...userSummary, email })
             )

    assert q.select == [{:field, ["id"]}, {:field, ["name"]}, {:field, ["email"]}]
  end

  test "a fragment spreading another fragment, resolved transitively", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(FRAGMENT base { id } FRAGMENT userSummary { ...base, name } SELECT users { ...userSummary })
             )

    assert q.select == [{:field, ["id"]}, {:field, ["name"]}]
  end

  test "a spread inside a nested SELECT's own body", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(FRAGMENT orderFields { id, total } SELECT users { name, SELECT orders { ...orderFields } })
             )

    assert q.select == [
             {:field, ["name"]},
             %Query{source: ["orders"], select: [{:field, ["id"]}, {:field, ["total"]}]}
           ]
  end

  test "spreading an undefined fragment is a compile error", %{grammar: g} do
    assert {:error, {:undefined_fragment, "doesNotExist"}} =
             run(g, ~s(SELECT users { ...doesNotExist }))
  end

  test "two FRAGMENTs sharing a name is a compile error, not silent last-write-wins", %{
    grammar: g
  } do
    assert {:error, {:duplicate_fragment, "f"}} =
             run(g, ~s(FRAGMENT f { id } FRAGMENT f { name } SELECT users { ...f }))
  end

  test "a fragment spreading itself, directly, is a compile error", %{grammar: g} do
    assert {:error, {:fragment_cycle, ["a", "a"]}} =
             run(g, ~s(FRAGMENT a { ...a } SELECT users { ...a }))
  end

  test "a fragment cycle through another fragment is a compile error", %{grammar: g} do
    assert {:error, {:fragment_cycle, ["a", "b", "a"]}} =
             run(g, ~s(FRAGMENT a { ...b } FRAGMENT b { ...a } SELECT users { ...a }))
  end

  test "a fragment spread alongside a plain field and a nested SELECT, order preserved", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s(FRAGMENT ids { id, uuid } SELECT users { name, ...ids, SELECT orders { total } })
             )

    assert q.select == [
             {:field, ["name"]},
             {:field, ["id"]},
             {:field, ["uuid"]},
             %Query{source: ["orders"], select: [{:field, ["total"]}]}
           ]
  end

  test "trailing whitespace after the query's own closing brace no longer fails to parse", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }) <> "\n")
    assert q.select == [{:field, ["name"]}]

    assert {:ok, %Query{}} = run(g, ~s(SELECT users { name }) <> "  \n\n  ")
  end

  test "a trailing comment after the query's own closing brace no longer fails to parse", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { name }) <> " # trailing note\n")
    assert q.select == [{:field, ["name"]}]
  end

  test "a function call as a computed field", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { total: sum(price) }])
    assert q.select == [{:computed, "total", {:call, "sum", [{:field, ["price"]}]}}]
  end

  test "a function call as a comparison's left-hand side, inside HAVING", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders GROUP BY id HAVING sum(total) > 200 { id }])

    assert q.havings == [{:cmp, :gt, {:call, "sum", [{:field, ["total"]}]}, 200}]
  end

  test "a bare identifier with no parens still parses as a plain field path, not a call", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT stats { sum, count }])
    assert q.select == [{:field, ["sum"]}, {:field, ["count"]}]
  end

  test "a function call nested inside arithmetic", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { x: sum(price) * 2 }])

    assert q.select == [
             {:computed, "x", {:arith, :mul, {:call, "sum", [{:field, ["price"]}]}, 2}}
           ]
  end

  test "a function call with a multi-argument arg list parses (arity isn't grammar-checked)", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { x: sum(price, tax) }])

    assert q.select == [
             {:computed, "x", {:call, "sum", [{:field, ["price"]}, {:field, ["tax"]}]}}
           ]
  end

  test "a function call as a comparison's left-hand side, plain WHERE", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders WHERE count(id) > 1 { id }])

    assert q.wheres == [{:cmp, :gt, {:call, "count", [{:field, ["id"]}]}, 1}]
  end

  test "a function call in an in [...] left-hand side", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s|SELECT orders GROUP BY id HAVING count(id) in [1, 2] { id }|)

    assert q.havings == [{:in, {:call, "count", [{:field, ["id"]}]}, [1, 2]}]
  end

  test "a WITH declaration binds a name to a full query, the lang_spec.md §9 worked example",
       %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s[WITH active_users = SELECT users WHERE status = "active" { id, name } SELECT active_users { name }]
             )

    assert q.source == ["active_users"]
    assert q.select == [{:field, ["name"]}]

    assert q.with_bindings == %{
             "active_users" => %Query{
               source: ["users"],
               wheres: [{:cmp, :eq, ["status"], "active"}],
               select: [{:field, ["id"]}, {:field, ["name"]}]
             }
           }
  end

  test "a query with no top-level WITH still parses with an empty with_bindings map", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT users { name }])
    assert q.with_bindings == %{}
  end

  test "two WITH declarations, resolved into the same with_bindings map", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s[WITH a = SELECT users { id } WITH b = SELECT orders { id } SELECT a { id }]
             )

    assert Map.keys(q.with_bindings) |> Enum.sort() == ["a", "b"]
  end

  test "two WITH declarations sharing a name is a compile error, not silent last-write-wins",
       %{grammar: g} do
    assert {:error, {:duplicate_with, "a"}} =
             run(
               g,
               ~s[WITH a = SELECT users { id } WITH a = SELECT orders { id } SELECT a { id }]
             )
  end

  test "a self-referencing WITH is a compile error", %{grammar: g} do
    assert {:error, {:with_cycle, ["a", "a"]}} =
             run(g, ~s[WITH a = SELECT a { id } SELECT a { id }])
  end

  test "a WITH cycle through another WITH binding is a compile error", %{grammar: g} do
    assert {:error, {:with_cycle, ["a", "b", "a"]}} =
             run(g, ~s[WITH a = SELECT b { id } WITH b = SELECT a { id } SELECT a { id }])
  end

  test "a WITH binding's own query can itself have full modifiers", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(
               g,
               ~s[WITH top = SELECT orders WHERE total > 10 ORDER BY total DESC LIMIT 5 { id } SELECT top { id }]
             )

    assert %Query{
             wheres: [{:cmp, :gt, ["total"], 10}],
             order_bys: [{["total"], :desc}],
             limit: 5
           } = q.with_bindings["top"]
  end

  test "a query with no combinator still parses as a plain %Query{}, not wrapped", %{grammar: g} do
    assert {:ok, %Query{}} = run(g, ~s[SELECT users { name }])
  end

  test "UNION parses to a %CombinedQuery{}", %{grammar: g} do
    assert {:ok, %CombinedQuery{op: :union, left: left, right: right}} =
             run(g, ~s[SELECT a { name } UNION SELECT b { name }])

    assert %Query{source: ["a"], select: [{:field, ["name"]}]} = left
    assert %Query{source: ["b"], select: [{:field, ["name"]}]} = right
  end

  test "UNION ALL parses to op: :union_all", %{grammar: g} do
    assert {:ok, %CombinedQuery{op: :union_all}} =
             run(g, ~s[SELECT a { name } UNION ALL SELECT b { name }])
  end

  test "INTERSECT parses to op: :intersect", %{grammar: g} do
    assert {:ok, %CombinedQuery{op: :intersect}} =
             run(g, ~s[SELECT a { name } INTERSECT SELECT b { name }])
  end

  test "EXCEPT parses to op: :except", %{grammar: g} do
    assert {:ok, %CombinedQuery{op: :except}} =
             run(g, ~s[SELECT a { name } EXCEPT SELECT b { name }])
  end

  test "a 3-way combinator chain folds left-associative, (A op1 B) op2 C", %{grammar: g} do
    assert {:ok,
            %CombinedQuery{
              op: :except,
              left: %CombinedQuery{
                op: :union,
                left: %Query{source: ["a"]},
                right: %Query{source: ["b"]}
              },
              right: %Query{source: ["c"]}
            }} =
             run(g, ~s[SELECT a { name } UNION SELECT b { name } EXCEPT SELECT c { name }])
  end

  test "a FRAGMENT spread resolves on both sides of a combinator", %{grammar: g} do
    assert {:ok, %CombinedQuery{left: left, right: right}} =
             run(
               g,
               ~s[FRAGMENT f { id, name } SELECT a { ...f } UNION SELECT b { ...f }]
             )

    assert left.select == [{:field, ["id"]}, {:field, ["name"]}]
    assert right.select == [{:field, ["id"]}, {:field, ["name"]}]
  end

  test "a WITH binding's own value cannot itself use a combinator (scope boundary)", %{
    grammar: g
  } do
    assert {:error, _} =
             run(
               g,
               ~s[WITH x = SELECT a { name } UNION SELECT b { name } SELECT x { name }]
             )
  end

  test "a nested SELECT body item cannot itself use a combinator (scope boundary)", %{
    grammar: g
  } do
    assert {:error, _} =
             run(g, ~s[SELECT users { name, SELECT a { id } UNION SELECT b { id } }])
  end

  test "count(distinct ...) parses to a {:distinct, expr} wrapped argument", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders { c: count(distinct customer_id) }])

    assert q.select == [
             {:computed, "c", {:call, "count", [{:distinct, {:field, ["customer_id"]}}]}}
           ]
  end

  test "an ordinary count(...) with no distinct is completely unaffected", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { c: count(id) }])
    assert q.select == [{:computed, "c", {:call, "count", [{:field, ["id"]}]}}]
  end

  test "a multi-arg call with no distinct on any argument still parses unchanged", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { x: sum(price, tax) }])

    assert q.select == [
             {:computed, "x", {:call, "sum", [{:field, ["price"]}, {:field, ["tax"]}]}}
           ]
  end

  test "distinct is syntactically permitted on any call's argument, not just count's", %{
    grammar: g
  } do
    # Grammar stays permissive (execution rejects misuse, see
    # ScryCore.ExecutorTest) -- confirms `sum(distinct x)` at least
    # *parses*, matching priv/grammar.aether's own `call_arg` comment.
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { x: sum(distinct price) }])
    assert q.select == [{:computed, "x", {:call, "sum", [{:distinct, {:field, ["price"]}}]}}]
  end

  test "json(<field>).path parses to {:dot, {:call, \"json\", args}, path}, the lang_spec.md §7 worked example",
       %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders WHERE json(metadata).color = "red" { id }])

    assert q.wheres == [
             {:cmp, :eq, {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["color"]}, "red"}
           ]
  end

  test "json(<field>).a.b supports a multi-segment path after the call", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { c: json(metadata).a.b }])

    assert q.select == [
             {:computed, "c", {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["a", "b"]}}
           ]
  end

  test "a bare call with no trailing dot-path still parses as a plain call, unaffected", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { m: json(metadata) }])
    assert q.select == [{:computed, "m", {:call, "json", [{:field, ["metadata"]}]}}]
  end

  test "call_with_path is syntactically permitted on any call, not gated to the name \"json\"", %{
    grammar: g
  } do
    # Grammar stays permissive (execution rejects misuse) -- confirms
    # e.g. `sum(price).foo` at least *parses*, matching
    # priv/grammar.aether's own `call_with_path` comment.
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { x: sum(price).foo }])
    assert q.select == [{:computed, "x", {:dot, {:call, "sum", [{:field, ["price"]}]}, ["foo"]}}]
  end

  test "in accepts a literal on the left and a plain field path as a computed list, the lang_spec.md §7 worked example",
       %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders WHERE "urgent" in metadata.tags { id }])

    assert q.wheres == [{:in, {:literal, "urgent"}, {:field, ["metadata", "tags"]}}]
  end

  test "in accepts a literal on the left and a bare call as a computed list", %{grammar: g} do
    assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders WHERE "urgent" in json(tags) { id }])
    assert q.wheres == [{:in, {:literal, "urgent"}, {:call, "json", [{:field, ["tags"]}]}}]
  end

  test "in accepts a literal on the left and a call narrowed by a dot-path as a computed list",
       %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders WHERE "urgent" in json(metadata).tags { id }])

    assert q.wheres == [
             {:in, {:literal, "urgent"},
              {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["tags"]}}
           ]
  end

  test "in accepts a field on the left against a computed list too, not just a literal", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} =
             run(g, ~s[SELECT orders WHERE status in json(metadata).valid_statuses { id }])

    assert q.wheres == [
             {:in, ["status"],
              {:dot, {:call, "json", [{:field, ["metadata"]}]}, ["valid_statuses"]}}
           ]
  end

  test "a literal bracketed list is still unaffected (items, not items_expr)", %{grammar: g} do
    assert {:ok, %Query{} = q} =
             run(g, ~s(SELECT users WHERE status in ["active", "pending"] { name }))

    assert q.wheres == [{:in, ["status"], ["active", "pending"]}]
  end

  test "a literal on the left of in against a literal bracketed list is unaffected too", %{
    grammar: g
  } do
    assert {:ok, %Query{} = q} =
             run(g, ~s|SELECT users WHERE "active" in ["active", "pending"] { name }|)

    assert q.wheres == [{:in, {:literal, "active"}, ["active", "pending"]}]
  end

  describe "window functions (lang_spec.md §5.5)" do
    test "row_number()/rank() parse with zero arguments", %{grammar: g} do
      assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { n: row_number() OVER }])
      assert q.select == [{:computed, "n", {:window, {:call, "row_number", []}, [], [], nil}}]

      assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { r: rank() OVER }])
      assert q.select == [{:computed, "r", {:window, {:call, "rank", []}, [], [], nil}}]
    end

    test "a call with no OVER is completely unaffected, including a zero-arg one", %{grammar: g} do
      assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { n: row_number() }])
      assert q.select == [{:computed, "n", {:call, "row_number", []}}]
    end

    test "the lang_spec.md §11 worked example, PARTITION BY and ORDER BY together", %{
      grammar: g
    } do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s[SELECT employees { name, rank: row_number() OVER PARTITION BY department ORDER BY salary DESC }]
               )

      assert q.select == [
               {:field, ["name"]},
               {:computed, "rank",
                {:window, {:call, "row_number", []}, [["department"]], [{["salary"], :desc}], nil}}
             ]
    end

    test "PARTITION BY alone, no ORDER BY or frame", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s[SELECT orders { n: row_number() OVER PARTITION BY region }])

      assert q.select == [
               {:computed, "n", {:window, {:call, "row_number", []}, [["region"]], [], nil}}
             ]
    end

    test "ORDER BY alone, no PARTITION BY or frame", %{grammar: g} do
      assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { n: row_number() OVER ORDER BY id }])

      assert q.select == [
               {:computed, "n", {:window, {:call, "row_number", []}, [], [{["id"], :asc}], nil}}
             ]
    end

    test "a full ROWS BETWEEN frame with a numeric bound on both sides", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s[SELECT orders { s: sum(total) OVER PARTITION BY region ORDER BY id ROWS BETWEEN 1 PRECEDING AND 2 FOLLOWING }]
               )

      assert q.select == [
               {:computed, "s",
                {:window, {:call, "sum", [{:field, ["total"]}]}, [["region"]], [{["id"], :asc}],
                 {{:preceding, 1}, {:following, 2}}}}
             ]
    end

    test "UNBOUNDED PRECEDING/FOLLOWING frame bounds", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s[SELECT orders { s: sum(total) OVER ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING }]
               )

      assert q.select == [
               {:computed, "s",
                {:window, {:call, "sum", [{:field, ["total"]}]}, [], [],
                 {:unbounded_preceding, :unbounded_following}}}
             ]
    end

    test "CURRENT ROW frame bounds", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s[SELECT orders { s: sum(total) OVER ORDER BY id ROWS BETWEEN CURRENT ROW AND CURRENT ROW }]
               )

      assert q.select == [
               {:computed, "s",
                {:window, {:call, "sum", [{:field, ["total"]}]}, [], [{["id"], :asc}],
                 {:current_row, :current_row}}}
             ]
    end

    test "OVER is syntactically permitted on any call name, grammar stays permissive", %{
      grammar: g
    } do
      assert {:ok, %Query{} = q} = run(g, ~s[SELECT orders { x: json(metadata) OVER }])

      assert q.select == [
               {:computed, "x", {:window, {:call, "json", [{:field, ["metadata"]}]}, [], [], nil}}
             ]
    end

    test "a window function can never reach WHERE -- a grammar-level restriction, not just execution-level",
         %{grammar: g} do
      # predicate_lhs/in_lhs and comparison's own right/right_field/
      # items/items_expr alternatives never reference window_call or
      # even expression/primary generally, so this is a genuine parse
      # error, confirmed here rather than assumed from reading the
      # grammar alone.
      assert {:error, _} =
               run(g, ~s[SELECT orders WHERE row_number() OVER > 1 { id }])
    end
  end

  describe "TYPE declarations (lang_spec.md §7) -- parsed, not yet consumed" do
    test "a plain, non-nullable type", %{grammar: g} do
      assert {:ok, %Query{} = q} = run(g, ~s(TYPE Employee { id: Int } SELECT users { id }))

      assert q.type_decls == %{
               "Employee" => %{
                 name: "Employee",
                 kind: nil,
                 fields: [{"id", {:named, "Int", nil}}]
               }
             }
    end

    test "a nullable field, the ? prefix", %{grammar: g} do
      assert {:ok, %Query{} = q} = run(g, ~s(TYPE Employee { age: ?Int } SELECT users { id }))

      assert q.type_decls == %{
               "Employee" => %{
                 name: "Employee",
                 kind: nil,
                 fields: [{"age", {:nullable, {:named, "Int", nil}}}]
               }
             }
    end

    test "a backend kind tag", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s(TYPE Employee: relational { id: Int } SELECT users { id }))

      assert q.type_decls["Employee"].kind == "relational"
    end

    test "a union type, the lang_spec.md §7 worked example", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s(TYPE Event { field: String | Int } SELECT users { id }))

      assert q.type_decls["Event"].fields == [
               {"field", {:union, [{:named, "String", nil}, {:named, "Int", nil}]}}
             ]
    end

    test "? binds to the immediately following base-type only, not a trailing union chain",
         %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s(TYPE T { f: ?Int | String } SELECT users { id }))

      assert q.type_decls["T"].fields == [
               {"f", {:union, [{:nullable, {:named, "Int", nil}}, {:named, "String", nil}]}}
             ]
    end

    test "Json<{...}>, the lang_spec.md §7 worked example for an inline shape", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s(TYPE Purchase: relational { metadata: Json<{ color: String, size: ?Int }> } SELECT users { id })
               )

      assert q.type_decls["Purchase"] == %{
               name: "Purchase",
               kind: "relational",
               fields: [
                 {"metadata",
                  {:named, "Json",
                   {:shape,
                    [
                      {"color", {:named, "String", nil}},
                      {"size", {:nullable, {:named, "Int", nil}}}
                    ]}}}
               ]
             }
    end

    test "Json<[Type]>, a list-parameterized generic", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s|TYPE Purchase { tags: Json<[String]> } SELECT users { id }|)

      assert q.type_decls["Purchase"].fields == [
               {"tags", {:named, "Json", {:list, {:named, "String", nil}}}}
             ]
    end

    test "Json used bare, with no parameter at all", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s(TYPE Purchase { metadata: Json } SELECT users { id }))

      assert q.type_decls["Purchase"].fields == [{"metadata", {:named, "Json", nil}}]
    end

    test "a generic parameter is syntactically permitted on any name, not gated to \"Json\"",
         %{grammar: g} do
      # Grammar stays permissive (execution/type-checking, not yet
      # implemented, would reject misuse) -- matches priv/grammar.aether's
      # own `base_type` comment.
      assert {:ok, %Query{} = q} =
               run(g, ~s(TYPE T { f: SomeGeneric<Int> } SELECT users { id }))

      assert q.type_decls["T"].fields == [{"f", {:named, "SomeGeneric", {:named, "Int", nil}}}]
    end

    test "multiple TYPE declarations coexist with FRAGMENT and WITH", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s(TYPE User { id: Int } TYPE Purchase { id: Int } FRAGMENT basics { id } WITH active = SELECT users { id } SELECT active { ...basics })
               )

      assert Map.keys(q.type_decls) |> Enum.sort() == ["Purchase", "User"]
      assert q.select == [{:field, ["id"]}]
    end

    test "a query with no TYPE declaration at all defaults to an empty map, unaffected", %{
      grammar: g
    } do
      assert {:ok, %Query{} = q} = run(g, ~s(SELECT users { id }))
      assert q.type_decls == %{}
    end

    test "two TYPEs sharing a name is a compile error, not silent last-write-wins", %{
      grammar: g
    } do
      assert {:error, {:duplicate_type, "T"}} =
               run(g, ~s(TYPE T { id: Int } TYPE T { id: Int } SELECT users { id }))
    end

    test "a type name colliding with an existing keyword needs backtick-escaping, same as any field name",
         %{grammar: g} do
      # lang_spec §3: "Escaped with backtick only on keyword collision" --
      # "order" is already KW_ORDER (ORDER BY), reclassified globally by
      # ScryCore.Grammar.KeywordRefiner regardless of grammar position,
      # so a bare `TYPE Order { ... }` doesn't parse; this is expected,
      # pre-existing behavior this feature inherits, not a new gap.
      assert {:error, _} = run(g, ~s(TYPE Order { id: Int } SELECT users { id }))

      assert {:ok, %Query{} = q} = run(g, ~s(TYPE `Order` { id: Int } SELECT users { id }))
      assert Map.has_key?(q.type_decls, "Order")
    end

    test "a combined query (UNION) still gets its own type_decls attached", %{grammar: g} do
      assert {:ok, %ScryCore.CombinedQuery{} = q} =
               run(
                 g,
                 ~s(TYPE T { id: Int } SELECT users { id } UNION SELECT customers { id })
               )

      assert Map.has_key?(q.type_decls, "T")
    end
  end

  describe "; block comments (lang_spec.md §3)" do
    test "comments out an entire alternate SELECT before the real one", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, "; SELECT orders { total }\nSELECT users { id }")

      assert q.source == ["users"]
    end

    test "comments out a TYPE declaration, a real one still parses", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, "; TYPE Bad { id: Int }\nTYPE Good { id: Int }\nSELECT users { id }")

      assert Map.keys(q.type_decls) == ["Good"]
    end

    test "comments out a FRAGMENT declaration entirely", %{grammar: g} do
      assert {:ok, %Query{} = q} = run(g, "; FRAGMENT f { id }\nSELECT users { id }")
      assert q.source == ["users"]
    end

    test "comments out a WITH declaration entirely", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, "; WITH x = SELECT orders { id }\nSELECT users { id }")

      assert q.with_bindings == %{}
    end

    test "a real declaration followed by a commented-out one, order preserved", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, "TYPE A { id: Int }\n; TYPE B { id: Int }\nSELECT users { id }")

      assert Map.keys(q.type_decls) == ["A"]
    end

    test "depth-counts through a nested SELECT inside the commented-out construct", %{
      grammar: g
    } do
      assert {:ok, %Query{} = q} =
               run(g, "; SELECT users { name, SELECT orders { id } }\nSELECT users { id }")

      assert q.select == [{:field, ["id"]}]
    end

    test "a { or } inside a string literal in the commented-out construct doesn't affect depth counting",
         %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s(; SELECT users WHERE name = "a { b } c" { id }\nSELECT users { id }))

      assert q.source == ["users"]
    end

    test "the same, with a single-quoted string", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, ~s(; SELECT users WHERE name = 'a { b } c' { id }\nSELECT users { id }))

      assert q.source == ["users"]
    end

    test "the same, with a triple-quoted multiline string", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(
                 g,
                 ~s(; SELECT users WHERE name = """a { b } c""" { id }\nSELECT users { id })
               )

      assert q.source == ["users"]
    end

    test "a trailing # comment right after the closing brace is unaffected", %{grammar: g} do
      assert {:ok, %Query{} = q} =
               run(g, "; SELECT orders { id } # leftover note\nSELECT users { id }")

      assert q.source == ["users"]
    end

    test "case-insensitive keyword matching, same as every other structural keyword", %{
      grammar: g
    } do
      assert {:ok, %Query{} = q} = run(g, "; select orders { id }\nSELECT users { id }")
      assert q.source == ["users"]
    end

    test "an unterminated block comment is a compile error", %{grammar: g} do
      assert {:error, _} = run(g, "; SELECT users { id\nSELECT users { id }")
    end

    test "; not immediately followed by a recognized keyword is a compile error", %{
      grammar: g
    } do
      assert {:error, _} = run(g, "; users { id }\nSELECT users { id }")
    end

    test "real declarations are completely unaffected when no block comment is present", %{
      grammar: g
    } do
      assert {:ok, %Query{} = q} =
               run(g, "TYPE T { id: Int }\nFRAGMENT f { id }\nSELECT users { ...f }")

      assert Map.has_key?(q.type_decls, "T")
      assert q.select == [{:field, ["id"]}]
    end
  end
end
