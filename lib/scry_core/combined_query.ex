defmodule ScryCore.CombinedQuery do
  @moduledoc """
  `UNION`/`UNION ALL`/`INTERSECT`/`EXCEPT` (lang_spec.md §5.4, "Top-level,
  joining two complete `select` blocks") -- a real, separate result type
  from `ScryCore.Query.t()`, not a field bolted onto it. A chain of 3+
  combinators (`A UNION B EXCEPT C`) is a binary tree, and `EXCEPT`/
  `INTERSECT` aren't commutative -- `A EXCEPT B EXCEPT C` has to mean
  `(A EXCEPT B) EXCEPT C` (left-associative, the ordinary left-to-right
  SQL reading), not the reverse. After folding the first combinator, the
  "query so far" is already a combination of two others -- `Query.t()`'s
  own `source`/`wheres`/`select` fields have no way to represent that (an
  ordinary fetch-and-filter query never means "the result of two other
  queries combined"), so this struct exists to represent it honestly
  instead of overloading `Query.t()`.

  `left`/`right` are each `Query.t() | t()` -- a leaf is an ordinary
  query, an internal node is itself a combination (from a longer chain).
  `with_bindings`/`type_decls` both mirror `Query.t()`'s own fields of
  the same name and the same meaning -- each populated once, on
  whichever struct `document`'s own top-level result turns out to be
  (`ScryCore.Actions`' own `handle_rule(:document, ...)`); `with_bindings`
  is read from there by `ScryCore.Executor.run/4`'s public entry point,
  `type_decls` by nothing yet (`Query.t()`'s own moduledoc has the full
  "parsed, not yet consumed" scope reasoning).

  Deliberately scoped narrower than lang_spec's own grammar might allow
  in principle: a combinator only ever appears at the very top of a
  document (`priv/grammar.aether`'s own `document`/`combined_select`
  rules) -- never inside a `WITH` binding's own value (`with_decl` still
  references plain `select`) and never inside a nested `SELECT` body
  item (`body_item` still references plain `select` too). `WITH
  RECURSIVE` (lang_spec.md §5.4.1) is the one concrete case where a
  `WITH` binding *would* need to be combinable, and it's an explicitly
  separate, later increment (its own fixpoint-iteration executor logic,
  plus the graph variant's own `VIA`, per its own worked example) --
  revisit this boundary specifically then, not before. Keeping it this
  narrow for now is what lets `ScryCore.WithCycleCheck` stay completely
  untouched: every `with_bindings` value is still exactly `Query.t()`.
  """

  alias ScryCore.Query

  @type op :: :union | :union_all | :intersect | :except

  @type t :: %__MODULE__{
          op: op(),
          left: Query.t() | t(),
          right: Query.t() | t(),
          with_bindings: %{optional(String.t()) => Query.t()},
          type_decls: %{optional(String.t()) => Query.type_decl()}
        }

  defstruct [:op, :left, :right, with_bindings: %{}, type_decls: %{}]
end
