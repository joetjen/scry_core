defmodule Scry.Core do
  @moduledoc """
  The core grammar/compiler library for [Scry](https://github.com/joetjen/scry).

  Owns the kind-agnostic grammar (lexical structure, literals, core
  keyword/operator reference, core block structure, type system, core
  extended constructs), the EP1/EP2 extension-point declarations a kind
  library's own grammar fragment composes against, and the shared
  execution scaffold every kind's engine behaviour builds on top of. See
  `scry`'s `lang_spec.md` §2–§9 and `impl_spec.md` §1–§2 for the full
  design this implements.

  `parse/1` is the intended entry point for anything outside this
  package (`scry_test_engine_core`'s own integration tests, eventually
  a real adapter's) -- `Scry.Core.Grammar`/`Scry.Core.Grammar.Compiled`/
  `Scry.Core.Actions` are public too, but composing them by hand is
  exactly the friction this function exists to avoid.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Parses `source` (Scry query text) into a `%Scry.Core.Query{}` (or a
  `%Scry.Core.CombinedQuery{}`, if `source`'s own top level uses `UNION`/
  `UNION ALL`/`INTERSECT`/`EXCEPT`, lang_spec §5.4), using core's own
  grammar and `Scry.Core.Actions`. Core-only -- no kind's grammar
  fragment is merged in (`Scry.Core.GrammarCompose` exists, but nothing
  calls it here yet), so a query using a kind-specific extension point
  parses only as far as core's own "always fails" default for it
  allows.

  `source` may be zero or more top-level `FRAGMENT` declarations, zero
  or more top-level `WITH` declarations, then exactly one `SELECT` --
  optionally chained with one or more `UNION`/`UNION ALL`/`INTERSECT`/
  `EXCEPT`ed `SELECT`s (lang_spec §5.4/§5.11/§9, `priv/grammar.aether`'s
  own `document`/`combined_select` rules); any `...<fragment-name>`
  spread anywhere in that final result's own body (either side of a
  combinator included) is already fully resolved
  (`Scry.Core.FragmentResolver`) by the time this returns -- the returned
  value never contains a spread placeholder, only real
  `Query.body_item()` shapes, indistinguishable from having written the
  fragment's own fields out by hand at that position. `WITH` bindings
  are *not* resolved here the same way -- each stays a real
  `%Scry.Core.Query{}` of its own, collected into the returned value's
  own `with_bindings` field and only ever executed later, by
  `Scry.Core.Executor`, whenever something actually references the bound
  name as a source (`Scry.Core.WithCycleCheck` still runs here, though --
  a `WITH` binding that (directly or transitively) references itself is
  rejected before this function ever returns, not left to loop forever
  the first time `Scry.Core.Executor.run/3` tries it).
  """
  @spec parse(String.t()) :: {:ok, Query.t() | CombinedQuery.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    Scry.Core.Grammar.Compiled.run(source, nil)
  end
end
