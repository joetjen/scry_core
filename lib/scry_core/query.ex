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
  over literals, `{:field, path}`, `{:param, name}`, and `{:call, name,
  args}` (lang_spec.md §5.8's built-in functions), evaluated by
  `ScryCore.Executor` against the current row (and, via `{:field,
  ...}`, an enclosing row too, the same scope-chain correlation a
  `where` predicate already gets). `{:call, ...}` splits two ways there:
  `sum`/`avg`/`count`/`min`/`max` (`ScryCore.Executor.eval_aggregate/5`)
  only mean anything across a group's own member rows (tied to `group
  by`/`having`, §5.2), while `string`/`int`/`exact`/`inexact`
  (`ScryCore.Executor`'s own `apply_cast/2`) are ordinary per-row
  expressions, valid anywhere any other `expr()` is -- `inexact(...)` is
  also the one place a real native `float()` ever enters this whole
  type; every other numeric shape (`integer()`/`ScryCore.Rational.t()`)
  stays exact.

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

  `with_bindings` (lang_spec.md §9: `WITH <name> = SELECT ... { ... }`,
  "named reusable sub-query, SQL CTE equivalent" -- vs. `FRAGMENT`'s
  reusable *shape*, this is reusable *data*) is meaningful only on the
  *top-level* query `ScryCore.parse/1` hands back, the mirror image of
  `required`'s own "only meaningful when nested" -- it's document-global
  (any `WITH` declaration is visible from every nesting depth, not just
  the query that happens to reference it first), so `ScryCore.Executor`
  threads it unchanged through every level of recursion instead of
  reading it off each query it happens to be executing. A query whose
  own `source` is exactly `[name]` for some declared `WITH name = ...`
  is executed (fresh, every time it's referenced -- no caching; see
  `ScryCore.Executor`'s own moduledoc for the cost tradeoff, the same
  "correct, not necessarily efficient" posture `REQUIRED`'s own re-fetch
  cost already has) *instead of* calling the real engine's `fetch/2`,
  and its own result rows are used exactly as if they'd come from a real
  source. A `WITH`-bound value is a full `t()` (built by the exact same
  `select` grammar rule/`handle_rule` clause an ordinary query is), not
  a special restricted shape -- its own `where`/`group by`/`having`/etc.
  all apply normally. Whether a bare source name refers to a `WITH`
  binding or a real engine source is resolved at *execution* time, not
  parse time -- there's no distinguishing sigil the way `FRAGMENT`'s own
  `...` spread has, so a name with no matching `WITH` binding is simply
  assumed to be a real source, not a compile error. `WITH RECURSIVE`
  (lang_spec.md §5.4.1) isn't part of this -- it needs `UNION`/`UNION
  ALL` (§5.4) to mean anything at all, and neither combinator is
  implemented anywhere in this codebase yet.

  `expr()`'s own `{:call, name, args}` (lang_spec.md §5.8, the fixed
  built-in-function surface -- `sum`/`avg`/`count`/`min`/`max` and
  `string`/`int`/`exact`/`inexact` are the 9 names actually executable
  today; `json`/window functions/`count(distinct ...)` still deferred)
  is deliberately not restricted to a known `name` at this type's own
  level, the same way `:variant` isn't restricted to a known kind -- the
  grammar (and this type) accept any `identifier(args)` call (lang_spec
  §5.8's own framing: "anything else ... is either an EP2 namespaced
  extension call, or ... `logic`'s EP2 bare call"), and it's
  `ScryCore.Executor` that decides, at execution time, which names it
  actually knows how to run (`eval_aggregate/5` for the 5 aggregates,
  `apply_cast/2` for the 4 casts).

  `predicate()`'s own left-hand side (`{:cmp, op, lhs, rhs}`/`{:in, lhs,
  values}`) widens from a bare `path :: [String.t()]` to `[String.t()]
  | {:call, String.t(), [expr()]}` for the same reason -- lang_spec
  §11's own worked example needs `HAVING sum(total) > 200`, a function
  call on a comparison's *left* side, which a bare path alone can never
  be. Narrower than a full `expr()` on purpose (unlike `rhs`, which
  already accepts one): a bare field predicate still produces exactly
  the same plain `[String.t()]` this type always has, so every existing
  predicate shape is unaffected -- only the new call-as-lhs shape is new
  surface. The right-hand side is *not* widened the same way (`HAVING
  sum(a) > avg(b)`, a call on *both* sides, stays unsupported) -- the
  one concrete need is call-on-the-left-only.
  """

  @type expr ::
          term()
          | {:field, [String.t()]}
          | {:param, String.t()}
          | {:arith, :add | :sub | :mul | :div | :pow, expr(), expr()}
          | {:when, clauses :: [{predicate(), expr()}], else_expr :: expr()}
          | {:call, name :: String.t(), args :: [expr()]}

  @type predicate ::
          {:cmp, :eq | :not_eq | :lt | :gt | :le | :ge | :match,
           lhs :: [String.t()] | {:call, String.t(), [expr()]},
           rhs :: term() | {:field, [String.t()]} | {:param, String.t()}}
          | {:in, lhs :: [String.t()] | {:call, String.t(), [expr()]},
             values :: [term() | {:param, String.t()}]}
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
          variant: %{optional(atom()) => term()},
          with_bindings: %{optional(String.t()) => t()}
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
            variant: %{},
            with_bindings: %{}
end
