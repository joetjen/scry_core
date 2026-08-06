defmodule ScryCore.Query do
  @moduledoc """
  The shared target both Scry front ends converge on -- the text grammar
  (`priv/grammar.aether` + `ScryCore.Actions`) and, eventually, the
  Elixir-native builder (impl_spec.md §7: a macro DSL plus a composable
  functional API, neither implemented yet). Adapters and tier-4
  extensions only ever see this struct; neither knows or needs to know
  which front end produced it.

  Field shapes here match the full design in impl_spec.md §7, not just
  what `priv/grammar.aether`'s current Phase 1 subset can populate.
  `group_bys`/`havings`/`distinct`/`order_bys`/`limit`/`offset` are all
  populated now (the full lang_spec.md §5.2 header-modifier chain,
  minus `group by ... rollup`/`... cube`); `group_mode` is the one
  exception still stuck at its `:plain` default either way -- rollup/cube
  aren't in the grammar yet, so nothing ever sets it to anything else.
  `variant` is the extension slot an EP1(b)/(c)/(d)-shaped construct from
  a loaded kind populates (impl_spec.md §2); core itself never writes to
  it.

  `wheres` is a list, combined with `and`, even though the current
  grammar only ever produces zero or one entry (one `WHERE` clause per
  `select`, lang_spec.md §5.2) -- matching the composable builder API's
  eventual ability to push more than one (`ScryCore.Query.where/2`,
  impl_spec.md §7), not a speculative field with nothing behind it.

  A `select` entry is one of three shapes -- a plain field path, a
  nested query (`priv/grammar.aether`'s `body_item := select | ...`,
  ordinary PEG recursion, no extension point needed), or a kind's own
  EP1(b)/(c)/(d) body-item construct, tagged `:variant` and left
  unexamined by core the same way `variant` itself is. A nested query
  is `t()` directly, not wrapped in its own tag -- already
  self-describing via its struct, unlike the other two shapes.

  `predicate()`'s own `{:field, path}` (lang_spec.md §5.9: a
  comparison's right-hand side may be another field path, not just a
  literal) reuses the exact same tag `body_item()` uses above --
  structurally identical in both places (a path naming a field), just
  a predicate operand here instead of an output-projection marker.
  Worth knowing they're the same tag in two conceptually distinct
  positions, not two coincidentally-identical ones.

  `required` (lang_spec.md §6, "Correlation and joins") is meaningful
  only when this query is itself a nested body item -- it's read
  entirely by the *enclosing* query's own projection step (whether to
  drop the outer row when this one comes back empty), never by
  anything in this query's own pipeline. A top-level query's own
  `required` is simply never read by anything; don't go looking for
  where `ScryCore.Executor.run/3` checks its own flag, because it
  doesn't -- only a parent's view of a child's `required` matters.

  `rhs`/`values`'s own `{:param, name}` (lang_spec.md §5.7/§9) is a
  placeholder, not a value -- parsing never resolves it, since the real
  value is supplied separately, at execution time, via
  `ScryCore.Executor.run/4`'s own `params` argument.

  A `{:field, path}` body item's own optional third element
  (lang_spec.md §5.3/§9: `<field> IF $<param>`) is that same `{:param,
  name}` placeholder -- present only when the field was written with an
  `IF` suffix; `ScryCore.Executor` omits the field from the projected
  row entirely (not a `nil`-filled key) when the resolved parameter is
  falsy (`nil`/`false` -- nothing else is), the GraphQL `@include`/
  `@skip` equivalent this construct is modeled on.

  `{:computed, alias, expr}` (lang_spec.md §9: `<alias>: <expression>`,
  e.g. `subtotal: price * quantity`) is a body item computed from an
  `expr()` -- a small arithmetic AST (`+ - * ** /`, lang_spec.md §5.10)
  over literals, `{:field, path}`, and `{:param, name}`, the same two
  placeholder tags `predicate()` already uses, evaluated by
  `ScryCore.Executor` against the current row (and, via `{:field,
  ...}`, an enclosing row too, the same scope-chain correlation a
  `where` predicate already gets). No function calls yet (`sum(...)`
  etc., lang_spec.md §5.8) -- those are aggregate functions tied to
  `group by`/`having`, and neither is executed anywhere in this
  codebase yet either, so there's nothing real to call them against.

  A body item may also be written `...<fragment-name>` in query text
  (lang_spec.md §5.11/§9, GraphQL-style reusable shape) -- but that never
  appears as a shape in `body_item()` itself. `ScryCore.Actions` parses
  it to a transient `{:spread, name}` placeholder that
  `ScryCore.FragmentResolver` (invoked from `handle_rule(:document,
  ...)`, the real grammar root -- see `priv/grammar.aether`'s own
  `document` rule) always fully expands, in place, before `ScryCore.
  parse/1` ever returns -- one `t()` this module's own callers ever see
  has no notion of fragments at all, only the real body items a spread's
  own target fragment expanded into.

  `expr()`'s own `{:when, clauses, else_expr}` (lang_spec.md §5.6/§9:
  `WHEN <predicate> THEN <expr> [...] ELSE <expr>`, "inline, not a
  block") reuses `predicate()` directly for each clause's own
  condition -- the exact same AST a `where` clause already produces, so
  a `WHEN` can already do anything `WHERE` can. `ScryCore.Executor`
  evaluates `clauses` in order and resolves the first matching one's
  own expression, falling back to `else_expr` if none match -- `ELSE`
  is mandatory at the grammar level (no default, no implicit `nil`),
  not just a documented expectation.
  """

  @type expr ::
          term()
          | {:field, [String.t()]}
          | {:param, String.t()}
          | {:arith, :add | :sub | :mul | :div | :pow, expr(), expr()}
          | {:when, clauses :: [{predicate(), expr()}], else_expr :: expr()}

  @type predicate ::
          {:cmp, :eq | :not_eq | :lt | :gt | :le | :ge | :match, path :: [String.t()],
           rhs :: term() | {:field, [String.t()]} | {:param, String.t()}}
          | {:in, path :: [String.t()], values :: [term() | {:param, String.t()}]}
          | {:and, predicate(), predicate()}
          | {:or, predicate(), predicate()}
          | {:not, predicate()}

  @type body_item ::
          {:field, [String.t()]}
          | {:field, [String.t()], {:param, String.t()}}
          | {:computed, String.t(), expr()}
          | t()
          | {:variant, term()}

  @type t :: %__MODULE__{
          source: [String.t()] | nil,
          wheres: [predicate()],
          group_bys: [[String.t()]],
          group_mode: :plain | :rollup | :cube,
          havings: [predicate()],
          distinct: boolean(),
          order_bys: [{[String.t()], :asc | :desc}],
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          required: boolean(),
          select: [body_item()],
          variant: %{optional(atom()) => term()}
        }

  defstruct source: nil,
            wheres: [],
            group_bys: [],
            group_mode: :plain,
            havings: [],
            distinct: false,
            order_bys: [],
            limit: nil,
            offset: nil,
            required: false,
            select: [],
            variant: %{}
end
