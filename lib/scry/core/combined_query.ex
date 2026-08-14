defmodule Scry.Core.CombinedQuery do
  @moduledoc """
  `UNION`/`UNION ALL`/`INTERSECT`/`EXCEPT` (lang_spec.md §5.4, "Top-level,
  joining two complete `select` blocks") -- a real, separate result type
  from `Scry.Core.Query.t()`, not a field bolted onto it. A chain of 3+
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
  (`Scry.Core.Actions`' own `handle_rule(:document, ...)`); `with_bindings`
  is read from there by `Scry.Core.Executor.run/4`'s public entry point,
  `type_decls` by `Scry.Core.TypeCheck.check/1` (`Query.t()`'s own
  moduledoc has the full compile-time type-checking scope reasoning --
  applies identically here, since `Scry.Core.TypeCheck.Nodes` walks both
  sides of `t()` the same way it walks a nested `Query.t()`).

  A combinator appears at the very top of a document (`priv/
  grammar.aether`'s own `document`/`combined_select` rules), and now
  also as a `WITH`/`WITH RECURSIVE` binding's own value (`with_decl`
  references `combined_select` too, not plain `select`) -- never inside
  a nested `SELECT` body item (`body_item` still references plain
  `select`). `WITH RECURSIVE` (lang_spec.md §5.4.1) is the one real
  reason a `WITH` binding needed to be combinable at all: the recursive
  case is defined *as* a `UNION`/`UNION ALL` of a base case and a
  recursive case referencing the binding's own name, so `with_bindings`'
  own value type widened to match -- `Scry.Core.QueryOps`' own
  `resolve_source/5` (the `WITH`-binding resolution path) and
  `Scry.Core.WithCycleCheck` (updated to exempt a `{:recursive, ...}`-
  tagged binding's own direct self-reference, and to walk a
  `CombinedQuery.t()` binding value's own `left`/`right` sides for
  ordinary, non-recursive cycle detection) both handle this now.
  """

  alias Scry.Core.Query

  @type op :: :union | :union_all | :intersect | :except

  @type t :: %__MODULE__{
          op: op(),
          left: Query.t() | t(),
          right: Query.t() | t(),
          with_bindings: %{
            optional(String.t()) => Query.t() | t() | {:recursive, Query.t() | t()}
          },
          type_decls: %{optional(String.t()) => Query.type_decl()}
        }

  defstruct [:op, :left, :right, with_bindings: %{}, type_decls: %{}]
end
