defmodule Scry.Core.GrammarParityTest do
  @moduledoc """
  A permanent regression guard for the equivalence this session's own
  scratch verification established (before switching `Scry.Core.parse/1`
  from the interpreted `Grammar.VM` path to the compiled `Scry.Core.
  Grammar.Compiled` path) between the two backends -- including the
  specific construct flagged elsewhere as previously non-equivalent
  between them (`Scry.Core.Grammar.BlockCommentLexeme`, a `CustomLexeme`).
  If these two backends were ever to genuinely diverge, this is the
  test that should catch it, not a scratch script that no longer exists.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.Grammar.Compiled

  setup_all do
    {:ok, analyzed} = Scry.Core.Grammar.compile()
    %{grammar: analyzed}
  end

  @queries [
    {"plain", ~s(SELECT users { name })},
    {"where", ~s(SELECT users WHERE age > 18 { name })},
    {"group by + aggregate", "SELECT users GROUP BY status { status, total: count(name) }"},
    {"group by rollup",
     "SELECT sales GROUP BY ROLLUP(region, quarter) { region, quarter, total: sum(amount) }"},
    {"group by cube",
     "SELECT sales GROUP BY CUBE(region, quarter) { region, quarter, total: sum(amount) }"},
    {"line comment before query", "# a leading comment\nSELECT users { name }"},
    {"line comment mid query", "SELECT users # inline comment\nWHERE age > 18 { name }"},
    {"block comment (via a commented-out WITH decl) before a real query",
     ";with x = SELECT y { z }\nSELECT users { name }"},
    {"block comment containing braces in a nested body",
     ";with x = SELECT y { z, SELECT w { v } }\nSELECT users { name }"},
    {"body items separated by a bare newline, no comma", "SELECT users {\n  name\n  email\n}"},
    {"body items on the same line with no comma -- both backends must reject this identically",
     "SELECT users { name email }"},
    {"a trailing comma before the closing brace", "SELECT users { name, email, }"},
    {"an IF-clause field followed by a newline separator (the leak-regression case)",
     "SELECT users {\n  name\n  email IF $inc\n}"}
  ]

  for {label, query} <- @queries do
    test "#{label}: Grammar.VM and Scry.Core.Grammar.Compiled agree", %{grammar: grammar} do
      vm_result = Grammar.VM.run(grammar, unquote(query), Scry.Core.Actions, nil)
      compiled_result = Compiled.run(unquote(query), nil)

      assert vm_result == compiled_result
    end
  end
end
