defmodule Scry.Core.Query do
  @moduledoc """
  The shared target both Scry front ends converge on -- the text grammar
  (`priv/grammar.aether` + `Scry.Core.Actions`) and the Elixir-native
  builder (impl_spec.md §7: `from/2`, a macro DSL sugaring over the
  composable functional API below it). Adapters and tier-4 extensions
  only ever see this struct; neither knows or needs to know which front
  end produced it.

  Field shapes here match the full design in impl_spec.md §7, not just
  what `priv/grammar.aether`'s current Phase 1 subset can populate.
  `group_bys`/`group_mode`/`havings`/`distinct`/`order_bys`/`limit`/
  `offset` are all populated now -- the full lang_spec.md §5.2 header-
  modifier chain, `GROUP BY ... ROLLUP`/`... CUBE` (`group_mode`)
  included: text (`group_by_clause`'s own three alternatives, `priv/
  grammar.aether`) and the composable builder's `group_by_rollup/2`/
  `group_by_cube/2` below both set it, and `Scry.Core.QueryOps` runs it
  for real (that module's own moduledoc has the hierarchical-subtotal-
  row mechanics). `variant` is the extension slot an EP1(b)/(c)/(d)-
  shaped construct from a loaded kind populates (impl_spec.md §2); core
  itself never writes to it.

  `time_field` is a different kind of extension slot than `variant`:
  where `variant` must be fully lowered away (emptied) by the time
  `Scry.Core.Executor.run/3,4` runs (`Scry.Core.EngineBehaviour`'s own
  "what a kind package must guarantee" contract), `time_field` is a
  genuine top-level field a kind's own lowering pass may leave set
  *past* that point -- every query that never touches it simply keeps
  the default `nil`, zero behavior change. Today it has exactly one
  producer and one consumer: `scry_time_series`'s own `LAST <duration>
  OF <field>` lowering (`Scry.TimeSeries.Executor.lower_last/2`) sets
  it to `[field]` (the same path already used to build the `LAST`
  predicate itself) when it turns `LAST` into an ordinary `WHERE`
  filter, and `Scry.Core.QueryOps`'s own `rate(<duration>)` aggregate
  (lang_spec.md §5.8) is the only thing that ever reads it -- to know
  which field to measure elapsed time against, since `rate`'s own
  duration argument is deliberately independent of `LAST`'s (see that
  aggregate's own comment in `query_ops.ex` for why). Kept generic
  (not named after `rate` or `LAST`) on purpose, the same "grammar/type
  stays generic, execution decides what it means" posture `variant`/
  `{:call, ...}` already have -- nothing stops a future construct from
  reading or writing it too.

  `new/1` through `select/2`, below the struct definition, are impl_spec
  .md §7's own Layer 1 -- the composable functional API, "the one that
  matters most for dynamic query building" per that section's own
  framing. Every function operates on this module's own field shapes
  directly (a predicate is the exact `predicate()` shape `Scry.Core.
  parse/1` already produces, not a friendlier surface syntax). `from/2`,
  last, is Layer 2 -- the macro DSL sugaring over Layer 1, with a more
  ergonomic surface syntax, nested `from` (correlation) included; see
  its own doc for what's still out of scope.

  `wheres` is a list, combined with `and`, even though the current
  grammar only ever produces zero or one entry (one `WHERE` clause per
  `select`, lang_spec.md §5.2) -- matching the composable builder API's
  eventual ability to push more than one (`Scry.Core.Query.where/2`,
  impl_spec.md §7), not a speculative field with nothing behind it.

  A `select` entry is one of three shapes -- a plain field path, a
  nested query (`priv/grammar.aether`'s `body_item := select | ...`,
  ordinary PEG recursion, no extension point needed), or a kind's own
  EP1(b)/(c)/(d) body-item construct, tagged `:variant` and left
  unexamined by core the same way `variant` itself is. A nested query
  is `t()` directly, not wrapped in its own tag -- already
  self-describing via its struct, unlike the other two shapes.

  `predicate()`'s own `{:variant, term()}` is `body_item()`'s own
  `{:variant, term()}` idiom's counterpart one level down, for core's
  third extension point (EP1(e), `priv/grammar.aether`'s own
  `comparison_ep1e`, lang_spec.md §2/§8.5's `SEARCH`) -- an infix
  comparison-tier operator a kind's own fragment contributes, producing
  a `predicate()` core has no way to evaluate on its own. Unlike
  `select`'s own `:variant` (which only ever appears as a whole body
  item, never nested inside another body item), this one can appear
  *anywhere* an ordinary predicate can -- nested arbitrarily deep inside
  `{:and, ...}`/`{:or, ...}`/`{:not, ...}`, in either `wheres` or
  `havings` -- since `SEARCH` is an infix operator, syntactically
  interchangeable with `=`/`>`/etc. wherever a comparison is legal. The
  same `EngineBehaviour` contract that requires `query.variant` be
  empty and every body item's own `:variant` resolved before `Scry.Core
  .Executor.run/3,4` runs applies here too: a kind package contributing
  here must walk its own query's *entire* `wheres`/`havings` tree and
  fully lower every `{:variant, ...}` predicate leaf it finds, not just
  check the top level.

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
  where `Scry.Core.Executor.run/3` checks its own flag, because it
  doesn't -- only a parent's view of a child's `required` matters.

  `rhs`/`values`'s own `{:param, name}` (lang_spec.md §5.7/§9) is a
  placeholder, not a value -- parsing never resolves it, since the real
  value is supplied separately, at execution time, via
  `Scry.Core.Executor.run/4`'s own `params` argument.

  A `{:field, path}` body item's own optional third element
  (lang_spec.md §5.3/§9: `<field> IF $<param>`) is that same `{:param,
  name}` placeholder -- present only when the field was written with an
  `IF` suffix; `Scry.Core.QueryOps` omits the field from the projected
  row entirely (not a `nil`-filled key) when the resolved parameter is
  falsy (`nil`/`false` -- nothing else is), the GraphQL `@include`/
  `@skip` equivalent this construct is modeled on.

  `{:computed, alias, expr}` (lang_spec.md §9: `<alias>: <expression>`,
  e.g. `subtotal: price * quantity`) is a body item computed from an
  `expr()` -- a small arithmetic AST (`+ - * ** /`, lang_spec.md §5.10)
  over literals, `{:field, path}`, `{:param, name}`, and `{:call, name,
  args}` (lang_spec.md §5.8's built-in functions), evaluated by
  `Scry.Core.QueryOps` against the current row (and, via `{:field,
  ...}`, an enclosing row too, the same scope-chain correlation a
  `where` predicate already gets). `{:call, ...}` splits two ways there:
  `sum`/`avg`/`count`/`min`/`max` (`Scry.Core.QueryOps.eval_aggregate/6`)
  only mean anything across a group's own member rows (tied to `group
  by`/`having`, §5.2), while `string`/`int`/`exact`/`inexact`
  (`Scry.Core.QueryOps`'s own `apply_cast/2`) are ordinary per-row
  expressions, valid anywhere any other `expr()` is -- `inexact(...)` is
  also the one place a real native `float()` ever enters this whole
  type; every other numeric shape (`integer()`/`Scry.Core.Rational.t()`)
  stays exact.

  A body item may also be written `...<fragment-name>` in query text
  (lang_spec.md §5.11/§9, GraphQL-style reusable shape) -- but that never
  appears as a shape in `body_item()` itself. `Scry.Core.Actions` parses
  it to a transient `{:spread, name}` placeholder that
  `Scry.Core.FragmentResolver` (invoked from `handle_rule(:document,
  ...)`, the real grammar root -- see `priv/grammar.aether`'s own
  `document` rule) always fully expands, in place, before `Scry.Core.
  parse/1` ever returns -- one `t()` this module's own callers ever see
  has no notion of fragments at all, only the real body items a spread's
  own target fragment expanded into.

  `expr()`'s own `{:when, clauses, else_expr}` (lang_spec.md §5.6/§9:
  `WHEN <predicate> THEN <expr> [...] ELSE <expr>`, "inline, not a
  block") reuses `predicate()` directly for each clause's own
  condition -- the exact same AST a `where` clause already produces, so
  a `WHEN` can already do anything `WHERE` can. `Scry.Core.QueryOps`
  evaluates `clauses` in order and resolves the first matching one's
  own expression, falling back to `else_expr` if none match -- `ELSE`
  is mandatory at the grammar level (no default, no implicit `nil`),
  not just a documented expectation.

  `with_bindings` (lang_spec.md §9: `WITH <name> = SELECT ... { ... }`,
  "named reusable sub-query, SQL CTE equivalent" -- vs. `FRAGMENT`'s
  reusable *shape*, this is reusable *data*) is meaningful only on the
  *top-level* query `Scry.Core.parse/1` hands back, the mirror image of
  `required`'s own "only meaningful when nested" -- it's document-global
  (any `WITH` declaration is visible from every nesting depth, not just
  the query that happens to reference it first), so `Scry.Core.Executor`
  threads it unchanged through every level of recursion instead of
  reading it off each query it happens to be executing. A query whose
  own `source` is exactly `[name]` for some declared `WITH name = ...`
  is executed (fresh, every time it's referenced -- no caching; see
  `Scry.Core.Executor`'s own moduledoc for the cost tradeoff, the same
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
  (lang_spec.md §5.4.1) isn't part of this -- `UNION`/`UNION ALL` (§5.4)
  are implemented, but lang_spec's own worked example for the recursive
  case uses the graph variant's own `VIA` (§8.1, not implemented in this
  codebase), and the "relational hierarchical walk" alternative it
  mentions in prose has no concrete Scry syntax shown anywhere for how a
  recursive term would reference its own binding's prior-step rows --
  genuinely blocked on new correlation syntax that doesn't exist yet,
  not merely on the combinators it also needs.

  `type_decls` (lang_spec.md §7: `TYPE <name> [: <kind>] { <field>:
  <type> ... }`, "standalone artifacts, closer to DDL, never inline in a
  query") mirrors `with_bindings`' own shape and top-level-only scope --
  a `name => type_decl()` map, populated once by `document`'s own
  handler, meaningful only on the query/combined-query `Scry.Core.parse/1`
  hands back. `Scry.Core.TypeCheck.check/1` now reads it -- run
  unconditionally, right after `type_decls` itself is attached, inside
  the same `handle_rule(:document, ...)` that builds it
  (`Scry.Core.Actions`) -- for lang_spec §7's compile-time category
  check, declared-field-type/union comparison check, `JSON`/`DXN`/
  `DXNB<Type>` field-access validation, and flow-sensitive null-safety
  narrowing, matched against whichever query node's own single-segment
  `source` is byte-for-byte identical to a declared `TYPE`'s own name
  (see that module's own moduledoc for the full matching rule and each
  check's exact scope). `Scry.Core.TypeCheck.Introspection` layers an
  optional, explicitly opt-in second pass on top -- a real adapter's own
  `describe_source/2` (`Scry.Core.EngineBehaviour`) filling in a source
  no inline `TYPE` declares at all -- invoked via `Scry.Core.
  check_types/3`, never automatically, since it needs a live connection
  and `Scry.Core.parse/1` stays a pure string-in/struct-out function.

  §7's *runtime* null-safety rule ("comparing a nullable field directly
  against a typed value is a hard error — always at runtime") **has**
  landed, independently of `type_decls`/a registry -- it needs neither,
  since it's about a row's own actual field *value* being `nil` at
  execution time, not a schema's own declared nullability.
  `Scry.Core.QueryOps`'s three `{:cmp, ...}` evaluators (`WHERE`/`WHEN`,
  and both the eager and streaming `HAVING` paths, kept in parity) all
  hard-error the moment either side of an ordinary comparison resolves
  to `nil`, with one explicit exemption: `field = nil`/`field != nil`
  (a literal `nil` on the right, exactly the shape `KW_NIL` always
  produces) is lang_spec's own null-check idiom, never hard-erroring
  regardless of what the field's own value is -- the mechanism §7's
  worked examples (`WHERE NOT (age = nil) AND age > 30`, `WHERE age =
  nil OR age > 30`) rely on, and Elixir's own short-circuiting `and`/
  `or` (already how `eval_predicate/4`'s own `{:and, ...}`/`{:or, ...}`
  clauses are implemented) makes both flow-sensitive at runtime for
  free, no extra narrowing logic needed on top. `type_expr()` mirrors lang_spec's own EBNF verbatim (`<type> ::=
  <base-type> | ?<base-type> | <type> | <type>`) -- `{:named, name,
  param}` covers every bare type name (`Int`, `String`, a reference to
  another declared `TYPE`, and `Json`/`Json<...>` uniformly, *not*
  gated to the literal name `"Json"` -- the grammar stays permissive
  the same way `call_with_path`/`DISTINCT` already are for their own
  generic constructs), `{:nullable, ...}` the `?` prefix, `{:union,
  [...]}` a flattened (not binary-tree) list since union has no
  associativity/directionality concern the way `EXCEPT`/`INTERSECT` do,
  `{:shape, [...]}` an inline anonymous shape (`Json<{ color: String,
  ... }>`), and `{:list, ...}` a list-of-type shape (`Json<[Type]>`) --
  not restricted to appearing only inside a `Json<...>` parameter at
  this type's own level, same permissive posture.

  `expr()`'s own `{:call, name, args}` (lang_spec.md §5.8, the fixed
  built-in-function surface -- `sum`/`avg`/`count`/`min`/`max`/
  `stddev_samp`/`stddev_pop`/`var_samp`/`var_pop`/`percentile`/`rate`,
  `string`/`int`/`exact`/`inexact`, `json`, and (only meaningful wrapped
  in `{:window, ...}` below) `row_number`/`rank`/`first_value`/
  `last_value` are the 20 names actually executable today) is
  deliberately not restricted to a known `name` at this type's own
  level, the same way `:variant` isn't restricted to a known kind -- the
  grammar (and this type) accept any `identifier(args)` call (lang_spec
  §5.8's own framing: "anything else ... is either an EP2 namespaced
  extension call, or ... `logic`'s EP2 bare call"), and it's
  `Scry.Core.QueryOps` that decides, at execution time, which names it
  actually knows how to run (`eval_aggregate/6` for the 11 aggregates,
  `apply_cast/2` for the 5 casts -- `json` included, alongside
  `string`/`int`/`exact`/`inexact` -- and the window-value dispatch
  inside `compute_window_values/5` for the 4 window-only names).
  `rate(<duration>)` is the one aggregate that doesn't fit `sum`/`avg`'s
  own "reduce a flat list of per-row values" shape -- it needs the
  query's own `time_field` (below) too, so it skips `apply_aggregate/2`
  entirely and is computed directly inside `eval_aggregate/6`.

  `expr()`'s own `{:window, call, partition_by, order_bys, frame}`
  (lang_spec.md §5.5: "`<fn>() OVER [PARTITION BY <field>,...] [ORDER BY
  <field> [desc|asc],...] [ROWS BETWEEN <bound> AND <bound>]`") marks a
  call as a window function -- unlike every other `expr()` tag, its
  value depends on more than the current row: `partition_by` groups the
  query's own filtered row set (`[[String.t()]]`, the exact same shape
  `Query.t()`'s own `group_bys` field already has -- an empty list means
  "whole result as one partition," lang_spec's own default), `order_bys`
  sequences each partition (`[{[String.t()], :asc | :desc}]`, again the
  exact same shape `Query.t()`'s own `order_bys` field has, reused
  verbatim rather than inventing a parallel type), and `frame` (`nil` or
  a `{frame_bound(), frame_bound()}` pair) optionally restricts an
  aggregate-as-window-function to a sliding window within its own
  partition -- `nil` means "the whole partition, regardless of whether
  `order_bys` is present" (lang_spec's own explicit "deliberately not
  SQL's behavior" rule). `call` is `{:call, name, args}}` as always;
  `name` is either one of `@aggregate_names` (reused as a window
  function, e.g. a running `sum`) or one of the 4 window-only names
  (`row_number`/`rank`, zero-argument; `first_value`/`last_value`, one
  argument) -- `Scry.Core.QueryOps.compute_window_values/4` has the full
  per-name dispatch. Reachable only from `select`, both at the grammar
  level (`priv/grammar.aether`'s own `window_call`/`over_spec` comments)
  and semantically -- `Scry.Core.QueryOps`'s own `resolve_rhs/4` and
  every sibling resolver reject a `{:window, ...}` node reached from
  `where`/`having`/a nested `GROUP BY` key with a clear error, since a
  window function's value depends on the *whole* filtered row set, which
  none of those positions have (real SQL has the identical restriction).
  Combining a real `GROUP BY`/aggregate query with a window function in
  the same `select` (`group_mode: :plain` only -- `ROLLUP`/`CUBE`
  combined with a window function is still a real, documented "not
  supported yet" gap) applies the window function *after* `GROUP BY`/
  `HAVING`, over the already-grouped/aggregated output rows -- real SQL
  semantics, and `Scry.Core.QueryOps.run_grouped_with_windows/7`'s own
  moduledoc has the full reasoning. `frame_bound()` (below) mirrors
  lang_spec's own 5-shape enumeration exactly (`UNBOUNDED PRECEDING`,
  `<n> PRECEDING`, `CURRENT ROW`, `<n> FOLLOWING`, `UNBOUNDED
  FOLLOWING`) -- a plain tagged value, not a struct, matching this
  module's own general preference for the lightest shape that carries
  the necessary data.

  `expr()`'s own `{:distinct, expr}` (lang_spec.md §5.8: `count(distinct
  …)`, "Distinct-value count") is meaningful only as `count`'s own
  single argument (`Scry.Core.QueryOps.eval_aggregate/6` dedupes the
  resolved per-member-row values before counting) -- syntactically
  permitted as a prefix on *any* call argument (`priv/grammar.aether`'s
  own `call_arg` comment has the "grammar stays permissive, execution
  rejects misuse" reasoning, the same posture an unknown function name
  already has), but a real, clear error anywhere else (`sum(distinct
  x)`, or nested inside arithmetic).

  `expr()`'s own `{:dot, base, path}` (lang_spec.md §5.8/§7: `json(
  <field>)`, "reinterprets a String field for one qualified use" --
  `WHERE json(metadata).color = "red"`) is a call's own *result*
  narrowed by an ordinary dot-path afterward -- `base` is any `expr()`
  (in practice always `{:call, "json", [...]}`, but not restricted to
  that at this type's own level, the same "grammar stays permissive"
  posture `{:distinct, ...}` already has), `path` an ordinary
  `[String.t()]`. `Scry.Core.QueryOps` resolves `base` first (through
  whichever resolver reached this node -- row-scoped or group-scoped,
  same composition every other nested `expr()` tag already gets for
  free) and walks `path` into the result the exact same way `{:field,
  ...}` already walks a path into a row -- `json(...)`'s own decoded
  value is an ordinary map with string keys, indistinguishable from row
  data once decoded.

  `predicate()`'s own left-hand side (`{:cmp, op, lhs, rhs}`/`{:in, lhs,
  values}`) widens from a bare `path :: [String.t()]` to `[String.t()]
  | {:call, String.t(), [expr()]} | {:dot, expr(), [String.t()]}` for
  the same reason -- lang_spec §11's own worked example needs `HAVING
  sum(total) > 200` (a function call on a comparison's *left* side) and
  §7's own needs `WHERE json(metadata).color = "red"` (a call's result,
  further narrowed by a dot-path, on that same left side), neither of
  which a bare path alone can ever be. Narrower than a full `expr()` on
  purpose (unlike `rhs`, which already accepts one): a bare field
  predicate still produces exactly the same plain `[String.t()]` this
  type always has, so every existing predicate shape is unaffected --
  only the new call/call-with-path-as-lhs shapes are new surface. The
  right-hand side is *not* widened the same way (`HAVING sum(a) >
  avg(b)`, a call on *both* sides, stays unsupported) -- the one
  concrete need is call-on-the-left-only.

  `{:in, lhs, values}`'s own `values` widens a second way, independent
  of the `lhs` widening above: from *only* `[term() | {:param, ...}]`
  (a literal bracketed list, resolved element by element) to *also*
  accept a single `{:field, [String.t()]} | {:call, String.t(),
  [expr()]} | {:dot, expr(), [String.t()]}` -- one expr() expected to
  resolve, as a whole, to the list to check membership against. Found
  while testing `json(<field>).path`: lang_spec §7's own worked example,
  `WHERE "urgent" in metadata.tags`, never parsed before this, since
  `in`'s own grammar alternative only ever matched a bracketed `[...]`
  literal. `Scry.Core.QueryOps.eval_predicate/4`'s own `{:in, ...}`
  clause dispatches on `is_list(values)` to tell the two shapes apart --
  the existing literal-list case is always a real Elixir list; the new
  computed-list case is always a tagged tuple, never a list, so the two
  can never be confused for one another.

  `{:in, lhs, values}`'s own `lhs` widens a *third* way, specific to
  `:in` alone (not shared with `:cmp`'s own `lhs`): it also accepts
  `{:literal, term()}`, a bare literal value wrapped for the same
  disambiguation reason `values`' own computed-list case needed
  wrapping. lang_spec §7's own worked example quoted above has a
  *literal* on `in`'s own left, `"urgent" in metadata.tags`, not a
  field -- `[String.t()] | {:call, ...} | {:dot, ...}` alone can never
  produce that. Not shared with `:cmp` (`"x" = status` has no worked
  example calling for it; `HAVING sum(total) > 200` is the one that
  does, already covered by the other two `lhs` shapes). The wrapping
  specifically prevents a literal *list* (`[1, 2] in ...`) from being
  silently misread as a two-segment field path by the same resolver
  that already treats any plain list it receives as one --
  `Scry.Core.QueryOps.resolve_predicate_lhs/4`'s own comment has the
  full reasoning.
  """

  @type frame_bound ::
          :unbounded_preceding
          | {:preceding, pos_integer()}
          | :current_row
          | {:following, pos_integer()}
          | :unbounded_following

  @type expr ::
          term()
          | {:field, [String.t()]}
          | {:param, String.t()}
          | {:arith, :add | :sub | :mul | :div | :pow, expr(), expr()}
          | {:when, clauses :: [{predicate(), expr()}], else_expr :: expr()}
          | {:call, name :: String.t(), args :: [expr()]}
          | {:distinct, expr()}
          | {:dot, base :: expr(), path :: [String.t()]}
          | {:window, call :: {:call, String.t(), [expr()]}, partition_by :: [[String.t()]],
             order_bys :: [{expr(), :asc | :desc}], frame :: {frame_bound(), frame_bound()} | nil}

  @type predicate ::
          {:cmp, :eq | :not_eq | :lt | :gt | :le | :ge | :match,
           lhs :: [String.t()] | {:call, String.t(), [expr()]} | {:dot, expr(), [String.t()]},
           rhs :: term() | {:field, [String.t()]} | {:param, String.t()}}
          | {:in,
             lhs ::
               [String.t()]
               | {:call, String.t(), [expr()]}
               | {:dot, expr(), [String.t()]}
               | {:literal, term()},
             values ::
               [term() | {:param, String.t()}]
               | {:field, [String.t()]}
               | {:call, String.t(), [expr()]}
               | {:dot, expr(), [String.t()]}}
          | {:and, predicate(), predicate()}
          | {:or, predicate(), predicate()}
          | {:not, predicate()}
          | {:variant, term()}

  @type body_item ::
          {:field, [String.t()]}
          | {:field, [String.t()], {:param, String.t()}}
          | {:computed, String.t(), expr()}
          | t()
          | {:variant, term()}

  @type type_expr ::
          {:named, name :: String.t(), param :: type_expr() | nil}
          | {:nullable, type_expr()}
          | {:union, [type_expr()]}
          | {:shape, [{String.t(), type_expr()}]}
          | {:list, type_expr()}

  @type type_decl :: %{
          name: String.t(),
          kind: String.t() | nil,
          fields: [{String.t(), type_expr()}]
        }

  @type t :: %__MODULE__{
          source: [String.t()] | nil,
          wheres: [predicate()],
          group_bys: [[String.t()]],
          group_mode: :plain | :rollup | :cube,
          havings: [predicate()],
          distinct: boolean(),
          order_bys: [{expr(), :asc | :desc}],
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          required: boolean(),
          select: [body_item()],
          variant: %{optional(atom()) => term()},
          with_bindings: %{optional(String.t()) => t()},
          type_decls: %{optional(String.t()) => type_decl()},
          time_field: [String.t()] | nil
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
            with_bindings: %{},
            type_decls: %{},
            time_field: nil

  @doc """
  Starts a new, empty query against `source` -- impl_spec.md §7's
  Layer 1, the composable functional counterpart to writing `SELECT
  <source> { ... }` as text. Every other function below takes the
  query it returns (or one already built up by another of them) as its
  own first argument, so a full query is assembled via `|>`, the same
  way `Ecto.Query`'s own functional API composes -- "the one that
  matters most for dynamic query building" per that section's own
  framing, since a caller already has well-typed data to hand these
  functions directly, not source text to interpolate into.

  Every function here operates on the exact same field shapes `t()`
  itself already has (a predicate is the same `predicate()` shape
  `Scry.Core.parse/1` already produces, a field path is the same
  `[String.t()]`, ...) rather than guessing at a friendlier surface
  syntax -- that ergonomic layer is impl_spec.md §7's own Layer 2 (a
  macro DSL built *on top of* these, not implemented yet), which this
  layer is the deliberately more mechanical foundation for.
  """
  @spec new([String.t()]) :: t()
  def new(source) when is_list(source), do: %__MODULE__{source: source}

  @doc """
  Adds one predicate to `query`'s own `wheres`, combined with every
  other one already there via `and` (`wheres` being a list is exactly
  for this -- see this module's own moduledoc). Each call adds one more
  clause on top of whatever's already there; call it more than once to
  build a conjunction up incrementally, the same composable way
  `Ecto.Query.where/3` does.
  """
  @spec where(t(), predicate()) :: t()
  def where(%__MODULE__{} = query, predicate), do: %{query | wheres: query.wheres ++ [predicate]}

  @doc """
  The `HAVING`-clause counterpart to `where/2` -- adds one predicate to
  `query`'s own `havings`, meaningful only alongside `group_by/2` (or
  the implicit whole-result group a query with no `group_by/2` call at
  all still gets, lang_spec.md §5.2), same as text `HAVING`.
  """
  @spec having(t(), predicate()) :: t()
  def having(%__MODULE__{} = query, predicate),
    do: %{query | havings: query.havings ++ [predicate]}

  @doc """
  Sets `query`'s own `group_bys` to `paths` -- a list of field paths,
  each path itself a list of segments for a dot-nested field, matching
  `t()`'s own `group_bys` type exactly rather than guessing at a
  flatter convenience shape (`group_by(query, [["region"]])`, not
  `group_by(query, ["region"])` -- the latter is genuinely ambiguous
  between "one two-segment nested path" and "two top-level fields," so
  this module doesn't try to guess). Replaces any prior `group_by/2`
  call rather than accumulating across calls the way `where/2`
  accumulates predicates -- lang_spec.md §5.2's own `GROUP BY <field>[,
  ...]` is one clause naming several fields, not several clauses.
  """
  @spec group_by(t(), [[String.t()]]) :: t()
  def group_by(%__MODULE__{} = query, paths) when is_list(paths),
    do: %{query | group_bys: paths, group_mode: :plain}

  @doc """
  `group_by/2`, with `group_mode: :rollup` (lang_spec.md §5.2's own
  `GROUP BY ... ROLLUP`, hierarchical subtotal rows in addition to the
  fully-grouped ones -- e.g. `ROLLUP(region, quarter)` also produces a
  per-`region` subtotal and a grand total, `region`/`quarter` both
  projecting `nil` on the rows they're rolled up away from).
  `Scry.Core.Executor`'s own moduledoc has the full subtotal-row
  mechanics and its one real, documented limitation (no `GROUPING()`/
  `GROUPING_ID()` equivalent to tell a genuine `nil` source value apart
  from a rolled-up one).
  """
  @spec group_by_rollup(t(), [[String.t()]]) :: t()
  def group_by_rollup(%__MODULE__{} = query, paths) when is_list(paths),
    do: %{query | group_bys: paths, group_mode: :rollup}

  @doc "`group_by_rollup/2`, with `group_mode: :cube` instead (every subset of the given fields gets its own subtotal, not just each prefix) -- same mechanics/caveat."
  @spec group_by_cube(t(), [[String.t()]]) :: t()
  def group_by_cube(%__MODULE__{} = query, paths) when is_list(paths),
    do: %{query | group_bys: paths, group_mode: :cube}

  @doc """
  Sets (not accumulates) `query`'s own `distinct` flag -- `true` unless
  `bool` is passed explicitly, matching lang_spec.md §5.2's own bare
  `DISTINCT` (no argument) header modifier.
  """
  @spec distinct(t(), boolean()) :: t()
  def distinct(query, bool \\ true)

  def distinct(%__MODULE__{} = query, bool) when is_boolean(bool), do: %{query | distinct: bool}

  @doc """
  Sets (not accumulates) `query`'s own `order_bys` to `order_bys` --
  `{key, direction}` pairs matching `t()`'s own type exactly, the same
  "one clause, several keys" shape `group_by/2` has, since `ORDER BY`
  is a single clause with multiple keys too (lang_spec.md §5.2). `key`
  is any `expr()` (a plain field path is `{:field, path}`, matching
  `select/2`'s own body items and every other `expr()` position) --
  not restricted to a bare field the way it once was, since lang_spec.md
  §8.5's own `ORDER BY relevance() DESC` needs a call here too.
  """
  @spec order_by(t(), [{expr(), :asc | :desc}]) :: t()
  def order_by(%__MODULE__{} = query, order_bys) when is_list(order_bys),
    do: %{query | order_bys: order_bys}

  @doc "Sets `query`'s own `limit`. `nil` clears a previously-set one."
  @spec limit(t(), non_neg_integer() | nil) :: t()
  def limit(%__MODULE__{} = query, n) when (is_integer(n) and n >= 0) or is_nil(n),
    do: %{query | limit: n}

  @doc "Sets `query`'s own `offset`. `nil` clears a previously-set one."
  @spec offset(t(), non_neg_integer() | nil) :: t()
  def offset(%__MODULE__{} = query, n) when (is_integer(n) and n >= 0) or is_nil(n),
    do: %{query | offset: n}

  @doc """
  Sets `query`'s own `select` to `shape` -- a list of `body_item()`s,
  the projection this query's own execution produces per output row,
  the pipeable counterpart to writing `{ ... }` as text.
  """
  @spec select(t(), [body_item()]) :: t()
  def select(%__MODULE__{} = query, shape) when is_list(shape), do: %{query | select: shape}

  @doc """
  impl_spec.md §7's own Layer 2 -- the macro DSL sugaring over every
  function above, modeled on `Ecto.Query`'s own `from` (`Scry.Core.
  Query.From`, and its own `Scry.Core.Query.Escape`, have the full
  design and its two real divergences from Ecto's own model: Scry has
  no table-aliasing concept, and `^pin` maps to a *named* deferred
  parameter matching `$name`, not Ecto's positional one).

      import Scry.Core.Query

      query =
        from u in "users",
          where: u.age > 30,
          order_by: [desc: u.age],
          limit: 5,
          select: %{
            name: u.name,
            email: u.email,
            orders:
              from(o in "orders",
                where: o.total > 50 and o.user_id == u.id,
                having: sum(o.total) > 200,
                select: %{order_count: count(o.id), total_spent: sum(o.total)}
              )
          }

  -- impl_spec.md §7's own worked example, translated directly (nesting
  a `from` inside a `select:` shape is how a nested `SELECT { }` body
  with correlation to its own enclosing query is expressed; no special
  nested-block syntax needed, ordinary Elixir nesting already has the
  right shape). **One real correction to that section's own prose**,
  found by actually compiling this, not assumed: the nested `from`
  needs the explicit parens shown above -- a no-parens call as a
  container literal's own value is ambiguous to Elixir's parser (does
  a `where:` two lines down belong to the inner `from` or the outer
  `select:` map?), so `orders: from o in "orders", where: ...` alone,
  as that section's own prose literally shows it, doesn't actually
  compile.

  Expands entirely at compile time into a pipeline of the plain
  functions above (`new/1 |> where/2 |> group_by/2 |> ...`) -- the
  expanded code never calls back into this macro or `Scry.Core.Query.
  Escape` at runtime, only ordinary Layer 1 functions. A nested `from`
  needs its own *outer* `from`'s `source` to be a compile-time-known
  string (or list of strings) -- `Scry.Core.Query.From`'s own moduledoc
  has the reasoning; a `from` with no nested `from` inside it is
  unaffected either way, `source` can still be any runtime expression.

  Window functions (`over/2`, `Scry.Core.Query.Escape`'s own moduledoc
  has the full syntax): `over(row_number(), partition_by: [u.dept],
  order_by: [desc: u.salary])`, matching lang_spec.md §11's own worked
  example exactly.

  `select:` also accepts a list, mirroring lang_spec.md §9's own
  `<body-item> ::= <field> | <alias>: <field> | <alias>: <expression> |
  ... | nested SELECT` directly -- a bare item must be a field path
  (`u.name`), an aliased one is an ordinary keyword-list entry (`total:
  u.price * u.quantity`), and a nested `from` may appear bare, with no
  map key to get wrong:

      select: [
        u.name,
        total: u.price * u.quantity,
        orders: from(o in "orders", where: o.user_id == u.id, select: [o.id, o.total])
      ]

  The map form (`select: %{...}`) is unchanged and still the more
  ergonomic choice whenever every item has (or needs) an alias -- the
  list form exists for the cases lang_spec.md §9 allows that a map's
  mandatory keys cannot express, an unaliased field chief among them.
  """
  defmacro from(binding, opts \\ []) do
    Scry.Core.Query.From.build(binding, opts, %{}, __CALLER__)
  end
end
