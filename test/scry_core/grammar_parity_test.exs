defmodule ScryCore.GrammarParityTest do
  @moduledoc """
  A permanent regression guard for the equivalence this session's own
  scratch verification established (before switching `ScryCore.parse/1`
  from the interpreted `Grammar.VM` path to the compiled `ScryCore.
  Grammar.Compiled` path) between the two backends -- including the
  specific construct flagged elsewhere as previously non-equivalent
  between them (`ScryCore.Grammar.BlockCommentLexeme`, a `CustomLexeme`).
  If these two backends were ever to genuinely diverge, this is the
  test that should catch it, not a scratch script that no longer exists.
  """

  use ExUnit.Case, async: true

  alias ScryCore.Grammar.Compiled

  setup_all do
    {:ok, analyzed} = ScryCore.Grammar.compile()
    %{grammar: analyzed}
  end

  @queries [
    {"plain", ~s(SELECT users { name })},
    {"where", ~s(SELECT users WHERE age > 18 { name })},
    {"group by + aggregate", "SELECT users GROUP BY status { status, total: count(name) }"},
    {"line comment before query", "# a leading comment\nSELECT users { name }"},
    {"line comment mid query", "SELECT users # inline comment\nWHERE age > 18 { name }"},
    {"block comment (via a commented-out WITH decl) before a real query",
     ";with x = SELECT y { z }\nSELECT users { name }"},
    {"block comment containing braces in a nested body",
     ";with x = SELECT y { z, SELECT w { v } }\nSELECT users { name }"}
  ]

  for {label, query} <- @queries do
    test "#{label}: Grammar.VM and ScryCore.Grammar.Compiled agree", %{grammar: grammar} do
      vm_result = Grammar.VM.run(grammar, unquote(query), ScryCore.Actions, nil)
      compiled_result = Compiled.run(unquote(query), nil)

      assert vm_result == compiled_result
    end
  end
end
