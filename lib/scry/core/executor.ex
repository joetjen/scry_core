defmodule Scry.Core.Executor do
  @moduledoc """
  Kind-agnostic query execution: given a `%Scry.Core.Query{}` and any
  module implementing `Scry.Core.EngineBehaviour` plus its own
  connection/config term, fetches, filters, and projects -- the
  "shared AST-walking/result-shaping utilities generic across every
  implementation of that kind" impl_spec.md §2 already describes core
  as owning. A kind-specific executor (once a real kind exists) is
  expected to call into this for the parts of a query that are still
  just core (`where`/`select`), handling only its own EP1/EP2
  contributions itself.

  A body item tagged `:variant` (`Scry.Core.Query.body_item/0`) has no
  execution semantics defined here -- core doesn't know what a kind's
  own EP1(b)/(c)/(d) construct means, so `run/3` returns an explicit
  error rather than silently ignoring or mishandling one.

  **`GROUP BY`/`HAVING`/aggregate functions (lang_spec.md §5.2/§5.8).**
  `run/5` splits into `run_plain/6` (today's original, ungrouped
  per-row pipeline, byte-identical) and `run_grouped/6`
  (`aggregate_query?/1` decides which -- a real `GROUP BY`, or a
  function call anywhere in `select`/`havings`, triggers grouped
  execution). No explicit `GROUP BY` isn't a special case: `group_rows/3`
  returns one implicit group containing every filtered row when
  `query.group_bys` is empty, which is exactly what makes lang_spec
  §11's own nested, un-grouped `SELECT orders { count(id), sum(total) }`
  work -- it collapses to one output row, the same mechanism `GROUP BY`
  itself uses per distinct key. `query.group_mode` other than `:plain`
  (`:rollup`/`:cube`, lang_spec.md §5.2's own `GROUP BY ... ROLLUP`/
  `... CUBE`) runs `run_grouped/6` once per *grouping level* --
  `group_levels/2`'s own doc has the exact level sets (`ROLLUP`'s own
  prefix hierarchy, `CUBE`'s own full subset powerset) -- concatenating
  every level's own groups, finest detail first, grand total last by
  construction. A bare `{:field, path}` body item that names a `GROUP
  BY` column *not* active at a given group's own level projects `nil`
  (the standard SQL convention for a rolled-up-away column; this
  implementation stops there -- no `GROUPING()`/`GROUPING_ID()`
  equivalent to tell a real `nil` source value apart from a rolled-up
  one, a real, documented, `:plain` SQL has the identical ambiguity
  too and solves with those functions -- not attempted here). An
  aggregate expression needs no equivalent handling at all: it already
  operates over whatever `member_rows` its own level's grouping
  produced, correct by construction at every level without any
  rollup/cube-specific code of its own.

  **Parallel chunked processing (`process_chunks_parallel/4`).** Two
  paths share one runner: the fetched source is split into fixed-size
  batches (`parallel_chunk_size/0`, `config :scry_core,
  parallel_chunk_size: n`) processed independently across a bounded
  pool of supervised worker tasks (`Scry.Core.TaskSupervisor`,
  `parallel_max_concurrency/0`), merged back together *in fetch order*
  -- byte-identical to what a single process working through the same
  rows one at a time would produce, regardless of how many workers ran
  or in what order they finished. `process_chunks_parallel/4` itself
  knows nothing about aggregation or projection; it only batches,
  supervises, orders, and folds results via whichever `chunk_fun`/
  `merge_fun` its caller supplies:

  - **Streaming aggregation** (`run_grouped_streaming/7`) -- `sum`/
    `avg`/`count`/`min`/`max` (`count(distinct ...)` included) as the
    entire value of a `select`/`having` item, with `group_mode: :plain`.
    `chunk_fun` = `accumulate_chunk/5` (per-chunk group accumulators),
    `merge_fun` = `merge_group_state/2` (representative row per group,
    first-appearance order, every running total, all merged correctly
    across chunk boundaries -- that function's own comment has the
    complete reasoning). `percentile`/`stddev*`/`var*`, `ROLLUP`/`CUBE`,
    and anything wider than a bare aggregate call (nested inside
    arithmetic, a cast, a `WHEN`) fall back to the older, fully eager,
    single-process `run_grouped/6` path, unchanged.
  - **Plain `WHERE`+projection** (`run_plain_parallel/7`) -- a `LIMIT`-
    less, `ORDER BY`/`DISTINCT`/window-free, nested-`SELECT`-free plain
    query *whose `select` contains at least one real function call*
    (`select_has_call?/1` -- `json(...)`, `cast`/`string`, any `:call`
    node anywhere in a `select` item, `run/6`'s own dispatch has the
    exact eligibility). `chunk_fun` = `filter_and_project_chunk/8` (the
    same per-row `matches_all?/4`/`project/8` functions `run_plain/8`
    already uses, applied to a batch), `merge_fun` = plain list
    concatenation in submission order. Everything not eligible keeps
    using `run_plain_streaming/7` (`LIMIT`-bound: wants centralized
    early-stop, which this path can't give; a bare-field-only `select`:
    see below) or `run_plain/8` (`ORDER BY`/`DISTINCT`/windows: need
    the whole set materialized regardless).

    The `select_has_call?/1` gate exists because of a real, measured
    (not assumed) finding: a `select` of only bare field references is
    *slower* through this path than through `run_plain_streaming/7` --
    every matching row still has to be copied into a worker's mailbox
    and the projected result copied back out, and that copy cost
    dwarfs a bare field access's own near-zero per-row compute (+25%
    to +35% slower, measured directly on 200K/1M-row tables, at every
    chunk size tried). A `select` with a real function call is a
    different story -- the per-row compute is now large enough that
    parallelizing it is worth paying the same copy cost (a measured
    1.4-1.5x speedup with a `json(...)` decode + nested-path
    projection on the same tables). `select_has_call?/1` is a cheap,
    purely structural proxy for "expensive enough to be worth it", not
    a cost model -- `upper(name)` is a call but still cheap, and a
    callless-but-genuinely-costly projection isn't caught either -- but
    it matches the measured boundary between the two cases directly.

  Both trade the fully single-process streaming path's own tighter
  `O(distinct groups)` (or `O(1)`-per-row) memory bound for `O(...) +
  parallel_chunk_size * parallel_max_concurrency` in exchange for real
  wall-clock speedup on CPU-bound work over large sources -- neither
  does, or can, reduce the cost of the underlying fetch itself (a
  single connection/cursor is an inherently serial read), only the
  per-row processing on top of it. `Task.Supervisor.async_stream_
  nolink/4`, not a linked task, is what lets a worker's own crash
  surface as an ordinary, callers-can-rescue exception in whatever
  process called `Executor.run/4`, exactly like today's single-process
  behavior, instead of an uncatchable `EXIT` that kills it outright --
  `process_chunks_parallel/4`'s own comment has the full reasoning,
  including a real, previously-shipped bug this uncovered: a worker
  crashing from a genuine BEAM-level runtime error (a failed function-
  clause match, say) exits with a *raw* reason, not a pre-built
  exception struct the way an explicit `raise` does, and naively
  assuming otherwise silently degrades back into an uncatchable crash
  for exactly that case (`reduce_chunk_result/3`'s own comment has the
  fix: reconstruct the original raise/throw/exit via `:erlang.raise/3`
  rather than assume a struct is already there).

  `@aggregate_names` (`sum`/`avg`/`count`/`min`/`max`, plus `stddev_samp`/
  `stddev_pop`/`var_samp`/`var_pop`/`percentile` -- lang_spec §5.8's own
  full standard-aggregate list, `count(distinct ...)` included) are
  actually executable (`eval_aggregate/5`), every one of them also
  usable as a window function (`over`, §5.5 -- this module's own
  "Window functions" section, near the bottom, has the full mechanics)
  alongside the 4 window-only names `row_number`/`rank`/`first_value`/
  `last_value`. That closes lang_spec §5.8's entire built-in-function
  surface. Every aggregate hard-errors
  (`raise ArgumentError`) the moment any resolved operand is `nil`, per
  lang_spec.md's own "Aggregates over nullable fields hard-error the
  same way [as comparing a nullable field directly] -- no silent
  nil-skipping; filter explicitly first" -- no special-cased "COUNT
  skips nulls" the way SQL has. `count([])` is `0`; `sum`/`avg`/`min`/
  `max` of `[]` are `nil` -- real SQL's own empty-aggregate answers, and
  what makes a flat aggregate over zero filtered rows still produce
  exactly one well-defined output row. A `GROUP BY`'s own group context
  is just its member rows, never a separately tracked key map -- a
  plain field resolves against the group's first member row (every
  member of a well-formed group already carries the identical value for
  any field that's actually a `GROUP BY` field), the same "not enforced,
  but well-defined" posture this module already has for a non-grouped
  `order_by`/`distinct` field.

  A grouped/aggregate query's own output sorts (`sort_rows/3`) *after*
  projection, not before -- unlike `run_plain/6`, there's no "outside
  the projected shape" *source* row left to sort by once grouping has
  collapsed multiple rows into one; only the already-computed group/
  aggregate values exist. `maybe_dedupe/2`/`paginate/3` are otherwise
  fully shared, unchanged, between both paths.

  `distinct`/`order_bys`/`limit`/`offset` are applied in the pipeline
  lang_spec.md §6's own "Modifier ordering" paragraph describes: filter,
  group (grouped path only), having (grouped path only), sort
  (`order_bys` -- against each *source* row pre-projection on the plain
  path, see `sort_rows/3`'s own comment for why; against each
  *projected* row post-projection on the grouped path, see above),
  project, dedupe (`distinct`, the block's *projected* output shape per
  §6's "Deduplication semantics", preserving first-occurrence order),
  then paginate (`limit`/`offset`). lang_spec.md §5.2's own "ordering by
  a field outside the projected shape while distinct is active is a
  compile-time error" is **not** enforced here -- no static/compile-time
  validation pass exists anywhere in this codebase yet; this module
  still produces a well-defined, deterministic result for that case
  (sorted, pre-dedup order breaks the tie for which duplicate's position
  "wins"), it just doesn't reject it the way a real compiler eventually
  should.

  **Correlation and `REQUIRED` (lang_spec.md §6, "Correlation and
  joins").** A nested `SELECT` body item's own `where` can reference an
  *enclosing* query's row -- a path whose first segment matches an
  ancestor `select`'s own source name (`List.last(source)`, the same
  name this module already uses as the nested-output map key) resolves
  against that ancestor's row instead of the current one, nearest
  enclosing match first. There is **no self-qualification**: inside
  `SELECT orders {...}`, a path starting with `orders.` is *not*
  specially stripped -- it's read as an ordinary (likely absent) nested
  field on the current row, exactly as it would be with no enclosing
  query at all. Self-qualifying was deliberately rejected during design
  (not just left out): it would silently reinterpret ordinary nested-
  field access (`orders.total` meaning "this row's own nested `orders`
  key, then `total`") as "look up `total` on the current row directly"
  whenever a row happens to contain a field named after its own
  source's tail segment -- a real, silent behavior change for a
  document-shaped row, not a harmless redundancy. Dropping it keeps a
  top-level (non-nested) `run/3` call provably unaffected: an empty
  scope chain makes the ancestor-lookup branch below a strict no-op.
  A narrower residual risk remains in principle -- an *ancestor's*
  scope name colliding with a real nested-field name on a *descendant*
  row two or more levels down -- and is left undocumented-away rather
  than solved, the same honest posture `group_by`/`having`'s own gaps
  already get here.

  `REQUIRED` (`Scry.Core.Query.required`) is read entirely by the
  *enclosing* query's own projection step: if a `REQUIRED` nested
  query comes back with zero rows for a given outer row, that outer
  row is dropped from the final result entirely (INNER-JOIN-like);
  absent `REQUIRED`, the outer row survives regardless (today's
  existing default, LEFT-JOIN-like). Only these two states are
  supported -- not the full LEFT/RIGHT/INNER/OUTER JOIN vocabulary.
  RIGHT and FULL OUTER JOIN need a flat row with nulls standing in for
  a missing side; Scry's nested/hierarchical output has no equivalent
  flat shape, so there is no sensible place to nest a child that has
  no matching parent at all.

  **Cost.** A correlated, `REQUIRED`-marked nested query gets
  re-fetched from scratch (full source, no pushdown --
  `Scry.Core.EngineBehaviour`'s own documented limitation) once per
  *surviving* outer row, because `limit`/`offset` on the outer query
  only apply after projection. This isn't a new cost *class* -- an
  uncorrelated nested query already re-runs, redundantly, once per
  outer row today -- but correlation is exactly what makes a nested
  `SELECT` worth writing as a real join at real row counts, where this
  starts to matter rather than being an unexploited memoization
  opportunity.

  **External parameters (lang_spec.md §5.7/§9).** `$name` parses to the
  placeholder `{:param, name}` (`Scry.Core.Actions`) -- never resolved
  at parse time, since the real value is supplied separately, out of
  band. `run/4`'s own `params` argument (default `%{}`, so every
  existing 3-arity call site is unaffected) supplies it at execution
  time instead, wherever `{:param, name}` appears: a comparison's own
  right-hand side, or any element of an `in [...]` list (both resolved
  the same way, `resolve_rhs/4`). A query referencing a name absent
  from `params` raises `ArgumentError` -- deliberately, not an
  `{:error, _}` return: `run/3`'s own `@spec` promises exactly two
  outcomes, and threading a third failure mode through `Enum.filter`
  would need the same `Enum.reduce_while` restructuring `project`/
  `project_all` already have for a different reason (dropping a row
  outright), for what amounts to a caller-supplied-insufficient-input
  class of error, not a data-shaped one. Consistent with this module's
  existing posture elsewhere: a type mismatch (`~` against a
  non-string) already raises rather than returning `{:error, _}`.

  **Conditional field inclusion (lang_spec.md §5.3/§9, `<field> IF
  $<param>`).** A `{:field, path, {:param, name}}` body item is omitted
  from the projected row entirely when the resolved parameter is falsy
  (`nil`/`false`, Scry's own two falsy values) -- a genuinely absent
  key, not a `nil`-valued one, the GraphQL `@include`/`@skip`
  equivalent this is modeled on.

  **`WITH` named sub-queries (lang_spec.md §9, `Query.t()`'s own
  `with_bindings`).** A query whose own `source` is exactly `[name]` for
  a declared `WITH` binding is executed and its result rows used
  *instead of* calling `engine_module.fetch/2` -- checked, and only
  meaningfully checkable, at the moment a source would otherwise be
  fetched (`fetch_rows/6`), since there's no distinguishing sigil in the
  grammar the way a `FRAGMENT` spread's own `...` has; an unrecognized
  bare name just falls through to a real source, never an error.
  `with_bindings` passes through every level of recursion unchanged
  (`fetch_rows/6`, `project_item/8`'s own nested-`%Query{}` clause), the
  same as `params` -- document-global, not scope-dependent, so a
  correlated nested `SELECT` several levels deep can reference a
  top-level `WITH` binding exactly as easily as the query that declared
  it.

  **Cost, the same honest posture `REQUIRED`'s own paragraph above
  already has.** A `WITH` binding is re-executed, from scratch, *every
  time* its name is referenced as a source -- no caching/memoization.
  This is a deliberate simplification, not an oversight: a real cache
  would need to live somewhere across the entire recursive call tree
  (this module has no mutable state to keep one in without real
  restructuring), and "correct, not necessarily efficient" is already
  this codebase's established default (`Scry.Core.EngineBehaviour`'s own
  moduledoc, "no pushdown ... always correct, not necessarily
  efficient"). A `WITH` binding referenced once, or only from one place,
  pays no extra cost at all; one referenced from inside a correlated
  nested `SELECT` pays the same "re-fetch per surviving outer row" cost
  `REQUIRED`'s own paragraph already documents, compounded if the
  binding is itself layered on another `WITH` binding.

  **Query combinators (lang_spec.md §5.4, `UNION`/`UNION ALL`/
  `INTERSECT`/`EXCEPT`, `Scry.Core.CombinedQuery`).** `run/4`'s own
  argument may be a `%Scry.Core.CombinedQuery{}` instead of a plain
  `%Query{}` -- `run_any/6` dispatches on which, running both `left`/
  `right` fully and independently (each through its own complete
  pipeline: fetch, filter, group/aggregate, sort, project, dedupe,
  paginate -- no pushdown, no shared fetch, the same "correct, not
  necessarily efficient" posture as everywhere else in this module) and
  combining the two row lists (`combine_rows/3`). `union`/`intersect`/
  `except` (not `_all`) dedupe their own *result*, standard SQL:1999 set
  semantics; row membership for `intersect`/`except` uses ordinary
  `MapSet` structural equality, which has the identical, previously-
  undocumented `%DateTime{}`/`%NaiveDateTime{}` precision-mismatch gap
  `term_order/2`'s own comment already documents for *ordering* two such
  values -- found, not fixed, while writing this. A chain of 3+
  combinators folds left-associative at parse time (`priv/grammar.aether`
  's own `combined_select` comment), so `A EXCEPT B EXCEPT C` correctly
  means `(A EXCEPT B) EXCEPT C`, not the reverse (`EXCEPT`/`INTERSECT`
  aren't commutative). Combinators only ever appear at the very top of a
  document -- never inside a `WITH` binding's own value, never inside a
  nested `SELECT` body item (`Scry.Core.CombinedQuery`'s own moduledoc has
  the scoping reasoning) -- so `project_item`'s own nested-query clause
  keeps calling `run/6` directly, unchanged; only `run/4`'s own public
  entry and `fetch_rows/6`'s `WITH`-resolution clause go through
  `run_any/6`.

  **Explicit casts (lang_spec.md §5.8, `string`/`int`/`exact`/
  `inexact`).** A real, non-aggregate function call -- valid per-row,
  anywhere any other `expr()` is, unlike `sum`/`avg`/`count`/`min`/`max`
  (`@aggregate_names`), which only ever mean anything across a group's
  own member rows. `aggregate_query?/1`'s own call-detection
  (`*_has_aggregate_call?`) checks specifically for `@aggregate_names`,
  not "any call" -- narrowed for exactly this reason: before casts
  existed, *any* call forced grouped execution, since no non-aggregate
  call existed yet to tell apart from an aggregate one; left unnarrowed,
  an ordinary `SELECT products { p: string(price) }` would have wrongly
  collapsed into one flat-aggregate-shaped row instead of projecting one
  row per product. `apply_cast/2` is the shared dispatch, called from
  `resolve_rhs/4`/`resolve_predicate_lhs/4` (the per-row path) and
  `resolve_group_rhs/4`/`resolve_group_lhs/4` (the grouped path) alike,
  each already having resolved a cast's own arguments through *that call
  site's own* resolver first -- so a cast wrapping an aggregate
  (`string(sum(total))`) or a grouped field both work correctly for
  free, via ordinary recursion, not special-cased.

  `inexact(x)` is the one place a real native `float()` ever enters this
  whole pipeline -- `Scry.Core.Rational`'s own moduledoc has the
  contagion/comparison rules that follow from that (mixing exact and
  inexact in one arithmetic operation yields inexact; comparison instead
  converts a float to its own exact value first, never the reverse).
  `term_order/2`'s two `%Rational{}`-specific guards widen to accept a
  `float()` argument accordingly -- closing a gap this module's own
  comment used to flag as real-but-unimplemented ("a native float there
  isn't yet covered"), now that `inexact(...)` is what actually produces
  one.

  `*_has_aggregate_call?`'s own `{:call, ...}` clauses recurse into a
  call's own `args`, not just check its outer `name` -- found as a real,
  pre-existing gap while implementing `count(distinct ...)` below (not
  present before a cast could nest an aggregate inside it): without the
  recursion, `SELECT products { total: string(sum(price)) }` -- no
  explicit `GROUP BY` -- never triggered grouped/flat-aggregate execution
  at all, since `string` itself isn't in `@aggregate_names`, and instead
  hit the per-row rejection error `sum(...)` alone already has for a
  genuinely per-row context. Fixed, not just documented -- the "work
  correctly for free" claim two paragraphs up was true for *resolving* a
  nested aggregate's arguments, but detection needed the same recursion
  applied to it independently.

  **`count(distinct ...)` (lang_spec.md §5.8, "Distinct-value count").**
  `{:distinct, expr}` (`Query.expr()`'s own moduledoc) is deduped
  (`Enum.uniq/1`) after the same nil hard-error every other aggregate
  operand already gets, then counted -- `eval_aggregate/5`'s own two new
  clauses intercept it as `count`'s *specific* single-argument shape,
  declared before the generic single-argument clause (`[{:distinct,
  arg}]` would otherwise also structurally match `[arg]`, silently
  treating the whole tuple as `sum`/`avg`/etc.'s own literal argument
  value). `DISTINCT` is syntactically permitted on any call's argument at
  the grammar level (`priv/grammar.aether`'s own `call_arg`), not just
  `count`'s -- `sum(distinct x)` parses, then raises a real, clear error
  at execution time (the same "grammar stays permissive, execution
  rejects misuse" posture an unknown function name already has), same
  for a cast (`string(distinct x)`) via `resolve_rhs/4`/
  `resolve_group_rhs/4`'s own new `{:distinct, _}` rejection clauses.

  **`json(<field>).path...` (lang_spec.md §5.8/§7, "Reinterprets a
  String as JSON for one qualified dot-path access, no schema
  change").** `{:dot, base, path}` (`Query.expr()`'s own moduledoc) is a
  call's own result narrowed by an ordinary dot-path afterward --
  `json` itself is dispatched from `apply_cast/2` exactly like the 4
  numeric/string casts (`cast_to_json/1`, via Erlang/OTP's own `:json`
  stdlib module, no new dependency), decoding into a plain map with
  *string* keys, indistinguishable from row data once decoded. `{:dot,
  ...}`'s own resolution (all 4 call sites: `resolve_rhs/4`/
  `resolve_predicate_lhs/4`/`resolve_group_rhs/4`/`resolve_group_lhs/4`)
  resolves `base` through whichever resolver reached it, then walks
  `path` into the result via `get_path_in/2` -- the exact same helper
  `{:field, ...}` already walks a path into a row with, reused directly,
  not reimplemented. Every `*_has_aggregate_call?` clause gained a
  matching `{:dot, base, _path}` recursion into `base`, the same
  regression class `count(distinct ...)` above already found and fixed
  for `{:call, ...}`'s own `args` -- verified for real (`Scry.Core
  .ExecutorTest`), not assumed to carry over just because the shape
  looks similar.

  Found while testing (above), fixed in a later increment: lang_spec.md
  §7's own "List-valued subfields work with `in`" (`WHERE "urgent" in
  metadata.tags`) needed `in`'s own right-hand side to accept a field/
  call-derived list, not only a bracketed list *literal*. `comparison`'s
  own grammar now has `in:KW_IN items_expr:(call_with_path | call |
  path)` alongside the original `items:list` alternative, and `in`'s own
  *left*-hand side gained a fourth shape (`in_lhs`'s own `lhs_literal`)
  for lang_spec's exact worked example, a literal on `in`'s left -- see
  `priv/grammar.aether`'s own `comparison`/`in_lhs` comments, `Query`'s
  own `{:in, lhs, values}` moduledoc paragraphs, and this module's own
  `eval_predicate/4`/`eval_group_predicate/4`/`resolve_predicate_lhs/4`/
  `resolve_group_lhs/4` clauses below for the full mechanics.

  **Null-safety (lang_spec.md §7).** An ordinary comparison (`WHERE`/
  `WHEN`, and both `HAVING` paths) hard-errors the moment either side
  resolves to `nil` -- the same "no silent nil-skipping" rule this
  module's own aggregates already enforce (`raise_aggregate_nil_error/1`),
  just for a plain comparison instead of a reduction. One explicit
  exemption, matched ahead of the general rule: a *literal* `nil` on a
  `:cmp`'s own right-hand side (`field = nil`/`field != nil`, `KW_NIL`'s
  only possible shape) is lang_spec's own null-check idiom, never
  hard-erroring -- Elixir's own short-circuiting `and`/`or` (already how
  `{:and, ...}`/`{:or, ...}` are evaluated here) is what makes both of
  §7's own worked examples (`WHERE NOT (age = nil) AND age > 30`,
  `WHERE age = nil OR age > 30`) flow-sensitively safe at runtime for
  free, no separate narrowing pass needed. This is the *runtime* half of
  §7's null-safety rule only -- it needs no schema/registry, since it's
  about a row's own actual value, not a declared type; the *compile-time*
  half (rejecting an unguarded nullable-field comparison statically,
  wherever a schema is reachable) is real, separate work gated on
  `Scry.Core.Query`'s own `type_decls`/a registry hook existing at all,
  neither of which do yet (`Scry.Core.Query`'s own moduledoc has the full
  "parsed, not yet consumed" scope reasoning).
  """

  alias Scry.Core.{CombinedQuery, Cursor, EngineBehaviour, Query, Rational}
  alias Scry.Core.Executor.QueryError

  @typedoc "One `{ancestor_source_name, ancestor_row}` per enclosing query, nearest first."
  @type scope :: [{String.t(), EngineBehaviour.row()}]

  @typedoc "External values bound to a query's own `$name` placeholders, by name."
  @type params :: %{optional(String.t()) => term()}

  @doc """
  Executes `query_or_combined` -- a `%Scry.Core.Query{}`, or a
  `%Scry.Core.CombinedQuery{}` (`UNION`/`UNION ALL`/`INTERSECT`/`EXCEPT`,
  lang_spec.md §5.4) -- against `engine_module` (a module implementing
  `Scry.Core.EngineBehaviour`) using `conn`, resolving any `$name`
  placeholder against `params`. For a plain `%Query{}`: one projected
  result row per source row surviving every predicate in `query.wheres`
  (combined with `and`), sorted, deduped, and paginated per
  `query.order_bys`/`query.distinct`/`query.limit`/`query.offset` -- or,
  if `query` uses `GROUP BY` or a function call anywhere in its
  `select`/`havings`, one row per group (or one flat-aggregate row with
  no explicit `GROUP BY`) instead. For a `%CombinedQuery{}`: both sides
  run fully and independently this same way, then their row lists are
  combined per `op`. See this module's own moduledoc for the exact
  pipeline order, the correlation/`REQUIRED`/external-parameter/`WITH`/
  combinator semantics, and the full `GROUP BY`/`HAVING`/aggregate-
  function story.

  Returns a `Scry.Core.Cursor.t()`, not a materialized list -- pull from
  it (`Cursor.next/1`/`take/2`/`to_list/1`) to actually get rows. A query
  that's genuinely stream-eligible (no `GROUP BY`/aggregate, no window
  function, no real `ORDER BY`, no `DISTINCT`) stays lazy all the way
  from the underlying `EngineBehaviour.fetch/2` source to whatever pulls
  from the returned cursor -- nothing in between materializes the whole
  row set. Everything else (real sorting/deduping/windows, or an
  aggregate this module can't stream incrementally -- `percentile`/
  `stddev*`/`var*`, or `ROLLUP`/`CUBE`) still computes its own result
  eagerly internally exactly as before, then wraps that finished list in
  a cursor at the very end -- correct either way, genuinely lazy only
  where it's actually achievable. A failure discoverable only mid-pull
  (today: a kind's own unrecognized EP1(b)/(c)/(d) body-item construct
  inside `select`) surfaces as a raised `Scry.Core.Executor.QueryError`
  when the caller pulls far enough to reach it, not as an `{:error, _}`
  return from this function -- `Scry.Core.Cursor`'s own moduledoc and
  `QueryError`'s own moduledoc both have the fuller "why a raise, not a
  tuple, for this one case" reasoning.
  """
  @spec run(Query.t() | CombinedQuery.t(), module(), term(), params()) ::
          {:ok, Cursor.t()} | {:error, term()}
  def run(query_or_combined, engine_module, conn, params \\ %{}),
    do:
      run_any(
        query_or_combined,
        [],
        params,
        query_or_combined.with_bindings,
        engine_module,
        conn
      )

  # Dispatches on which of the two top-level result shapes
  # `Scry.Core.parse/1` can produce (`Scry.Core.CombinedQuery`'s own
  # moduledoc) -- a plain `%Query{}` goes to `run/6` below, a
  # `%CombinedQuery{}` (`UNION`/`UNION ALL`/`INTERSECT`/`EXCEPT`,
  # lang_spec.md §5.4) to `run_combined/6`. Every recursive call site
  # that executes *something the grammar could have produced as either
  # shape* goes through this, not `run/6` directly -- today that's just
  # `fetch_rows/6`'s own `WITH`-binding-resolution clause below (a
  # nested `SELECT` body item, by contrast, is always plain `Query.t()`,
  # never combined -- `Scry.Core.CombinedQuery`'s own moduledoc has the
  # scoping reasoning -- so `project_item`'s own nested-query clause
  # keeps calling `run/6` directly, unchanged).
  @spec run_any(
          Query.t() | CombinedQuery.t(),
          scope(),
          params(),
          %{String.t() => Query.t()},
          module(),
          term()
        ) ::
          {:ok, Cursor.t()} | {:error, term()}
  defp run_any(%Query{} = query, scope, params, with_bindings, engine_module, conn),
    do: run(query, scope, params, with_bindings, engine_module, conn)

  defp run_any(%CombinedQuery{} = combined, scope, params, with_bindings, engine_module, conn),
    do: run_combined(combined, scope, params, with_bindings, engine_module, conn)

  # Runs both sides fully, independently, through their own complete
  # pipeline (fetch, filter, group/aggregate, sort, project, dedupe,
  # paginate -- whatever each side's own modifiers call for), then
  # combines the two row lists -- no pushdown, no shared fetch, the same
  # "correct, not necessarily efficient" posture this module's own
  # moduledoc already documents elsewhere. `left`/`right` are each
  # `Query.t() | CombinedQuery.t()` (`CombinedQuery`'s own moduledoc),
  # so this recurses through `run_any/6` again for an arbitrarily deep
  # chain, not just a single combinator. `combine_rows/3` (`Enum.uniq`/
  # `MapSet`-based set semantics) inherently needs both sides fully
  # materialized -- `drain_result/1` does that, converting a lazily-
  # raised `QueryError` from either side back into this module's own
  # ordinary `{:error, reason}` tuple first, so a genuinely broken *side*
  # of a combinator still surfaces the same way it always has.
  defp run_combined(
         %CombinedQuery{op: op, left: left, right: right},
         scope,
         params,
         with_bindings,
         engine_module,
         conn
       ) do
    with {:ok, left_rows} <-
           left |> run_any(scope, params, with_bindings, engine_module, conn) |> drain_result(),
         {:ok, right_rows} <-
           right |> run_any(scope, params, with_bindings, engine_module, conn) |> drain_result() do
      {:ok, Cursor.new(combine_rows(op, left_rows, right_rows))}
    end
  end

  # Materializes a `Cursor` back into this module's own long-established
  # `{:ok, [row()]} | {:error, reason}` tuple shape -- used at every
  # *internal* boundary that needs a concrete result right away (a
  # combinator's own two sides, above; a nested `SELECT`'s own embedded
  # result, `project_item/8` below), converting a lazily-raised `Query
  # Error` (the only way an error can surface once execution is
  # genuinely lazy -- `QueryError`'s own moduledoc has the reasoning)
  # back into a tuple, so every pre-existing internal caller built on
  # that tuple contract (`REQUIRED`, `combine_rows/3`) needs zero further
  # changes of its own.
  @spec drain_result({:ok, Cursor.t()} | {:error, term()}) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  defp drain_result({:error, _} = err), do: err

  defp drain_result({:ok, cursor}) do
    {:ok, Cursor.to_list(cursor)}
  rescue
    e in QueryError -> {:error, e.reason}
  end

  # `union`/`intersect`/`except` (not `_all`) dedupe their own *result*,
  # matching standard SQL:1999 set semantics (lang_spec.md §5.4's own
  # table only calls this out explicitly for `union`/`union all`, but
  # `INTERSECT`/`EXCEPT` are conventionally non-`ALL`, deduping set
  # operations too, the same way a bare `INTERSECT` differs from SQL's
  # own `INTERSECT ALL`). Row membership for `intersect`/`except` uses
  # ordinary `MapSet` structural equality (`==` on the whole row map) --
  # correct for every value type except the one gap this module's own
  # pre-existing `distinct` dedup already has, undocumented until now:
  # two `%DateTime{}`/`%NaiveDateTime{}` values representing the same
  # instant at different parsed precision aren't `==` (`term_order/2`'s
  # own comment has the fuller "confirmed empirically" story for why
  # *ordering* needed special handling; *equality* has the identical
  # underlying problem, just never surfaced until rows started getting
  # compared to each other directly here). Not fixed here -- same
  # "found, not solved" posture every other already-acknowledged gap in
  # this module already has.
  defp combine_rows(:union, left, right), do: Enum.uniq(left ++ right)
  defp combine_rows(:union_all, left, right), do: left ++ right

  defp combine_rows(:intersect, left, right) do
    right_set = MapSet.new(right)
    left |> Enum.filter(&MapSet.member?(right_set, &1)) |> Enum.uniq()
  end

  defp combine_rows(:except, left, right) do
    right_set = MapSet.new(right)
    left |> Enum.reject(&MapSet.member?(right_set, &1)) |> Enum.uniq()
  end

  @spec run(Query.t(), scope(), params(), %{String.t() => Query.t()}, module(), term()) ::
          {:ok, Cursor.t()} | {:error, term()}
  defp run(%Query{} = query, scope, params, with_bindings, engine_module, conn) do
    own_name = List.last(query.source)
    {windows, _rewritten} = collect_and_rewrite_window_calls(query.select)

    cond do
      windows != [] and aggregate_query?(query) and query.group_mode != :plain ->
        raise ArgumentError,
              "combining ROLLUP/CUBE with a window function in the same SELECT isn't " <>
                "supported yet"

      windows != [] and aggregate_query?(query) ->
        with {:ok, rows} <-
               run_grouped_with_windows(
                 query,
                 own_name,
                 scope,
                 params,
                 with_bindings,
                 engine_module,
                 conn
               ) do
          {:ok, Cursor.new(rows)}
        end

      aggregate_query?(query) and query.group_mode == :plain ->
        case streaming_aggregate_plan(query) do
          {:ok, plan} ->
            with {:ok, rows} <-
                   run_grouped_streaming(
                     query,
                     plan,
                     scope,
                     params,
                     with_bindings,
                     engine_module,
                     conn
                   ) do
              {:ok, Cursor.new(rows)}
            end

          :not_streamable ->
            with {:ok, filtered} <-
                   fetch_and_filter(query, scope, params, with_bindings, engine_module, conn),
                 {:ok, rows} <-
                   run_grouped(query, filtered, own_name, scope, params, engine_module, conn) do
              {:ok, Cursor.new(rows)}
            end
        end

      aggregate_query?(query) ->
        with {:ok, filtered} <-
               fetch_and_filter(query, scope, params, with_bindings, engine_module, conn),
             {:ok, rows} <-
               run_grouped(query, filtered, own_name, scope, params, engine_module, conn) do
          {:ok, Cursor.new(rows)}
        end

      windows == [] and query.order_bys == [] and not query.distinct and query.limit == nil and
        not select_has_nested_query?(query.select) and select_has_call?(query.select) ->
        run_plain_parallel(query, own_name, scope, params, with_bindings, engine_module, conn)

      windows == [] and query.order_bys == [] and not query.distinct ->
        run_plain_streaming(query, own_name, scope, params, with_bindings, engine_module, conn)

      windows == [] and query.order_bys != [] and not query.distinct and
        query.limit != nil and not select_can_skip_rows?(query.select) ->
        with {:ok, rows} <-
               run_topk_streaming(
                 query,
                 own_name,
                 scope,
                 params,
                 with_bindings,
                 engine_module,
                 conn
               ) do
          {:ok, Cursor.new(rows)}
        end

      true ->
        with {:ok, filtered} <-
               fetch_and_filter(query, scope, params, with_bindings, engine_module, conn),
             {:ok, rows} <-
               run_plain(
                 query,
                 filtered,
                 own_name,
                 scope,
                 params,
                 with_bindings,
                 engine_module,
                 conn
               ) do
          {:ok, Cursor.new(rows)}
        end
    end
  end

  # Shared by every path that still needs the *whole* filtered row set
  # materialized up front (`DISTINCT`/window functions on the plain side;
  # a real `ORDER BY` *without* a `LIMIT` to bound it -- `run_topk_
  # streaming/7`, below, handles the `ORDER BY` + `LIMIT` combination
  # without this; anything grouped that `streaming_aggregate_plan/1`
  # can't handle incrementally) -- `Cursor.to_list/1` here is the exact
  # same eager materialization `fetch_and_materialize/3` used to do
  # unconditionally, just now only reached when actually needed.
  defp fetch_and_filter(query, scope, params, with_bindings, engine_module, conn) do
    with {:ok, cursor} <- fetch_rows(query, scope, params, with_bindings, engine_module, conn) do
      filtered =
        cursor |> Cursor.to_list() |> Enum.filter(&matches_all?(&1, query.wheres, scope, params))

      {:ok, filtered}
    end
  end

  # A query whose own `source` is exactly `[name]` for a declared `WITH`
  # binding (`Query.t()`'s own `with_bindings`, lang_spec.md §9) runs
  # that binding -- fresh, every time, no caching (see this module's own
  # moduledoc for the cost tradeoff) -- instead of asking the real
  # engine to fetch it; its own result rows are used exactly as if
  # they'd come from a real source. `with_bindings` passes through
  # unchanged into the recursive call, the same way `params` already
  # does, since it's equally document-global, not scope-dependent.
  # `run_any/6`, not `run/6` directly -- the grammar can't currently
  # produce a `%CombinedQuery{}` as a `WITH` binding's own value
  # (`Scry.Core.CombinedQuery`'s own moduledoc has the scoping reasoning),
  # but keeping this dispatch generic costs nothing and avoids a latent
  # `FunctionClauseError` waiting for whenever that scope boundary is
  # revisited. Falls through to the real `fetch/2` for any multi-segment
  # source (a `WITH` name is always a single bare identifier, lang_spec
  # §9's own grammar) or a single-segment one that isn't a declared
  # binding -- deliberately not an error: there's no distinguishing
  # sigil the way a `FRAGMENT` spread's own `...` has, so an
  # unrecognized bare name is just assumed to be a real source (`Query`'s
  # own moduledoc).
  defp fetch_rows(
         %Query{source: [name]} = query,
         scope,
         params,
         with_bindings,
         engine_module,
         conn
       ) do
    case Map.fetch(with_bindings, name) do
      {:ok, bound_query} ->
        # `run_any/6` already returns `{:ok, Cursor.t()}` -- no extra
        # wrapping needed here, this is already the exact shape
        # `fetch_rows/6`'s own callers expect.
        run_any(bound_query, scope, params, with_bindings, engine_module, conn)

      :error ->
        fetch_lazy(engine_module, conn, [name], query)
    end
  end

  defp fetch_rows(
         %Query{source: source} = query,
         _scope,
         _params,
         _with_bindings,
         engine_module,
         conn
       ),
       do: fetch_lazy(engine_module, conn, source, query)

  # `engine_module.fetch/2` may return any `Enumerable.t()` now, not just
  # a plain list (`Scry.Core.EngineBehaviour`'s own moduledoc has the
  # reasoning) -- wrapped here in a `Scry.Core.Cursor` and handed back
  # *unmaterialized*. Whether this actually stays lazy any further
  # depends entirely on the caller: `run/6`'s own dispatch either drains
  # it immediately via `fetch_and_filter/6` (`DISTINCT`/window functions,
  # an `ORDER BY` with no `LIMIT`, or a grouped query `streaming_
  # aggregate_plan/1` can't handle incrementally -- all inherently need
  # the whole set regardless of how `fetch/2` returned its data), or
  # pulls from it one row at a time -- either genuinely lazily
  # (`run_plain_streaming/7`, `run_grouped_streaming/7`) or into a
  # bounded buffer that still needs every row *pulled*, just never more
  # than `limit + offset` of them held at once (`run_topk_streaming/7`,
  # for `ORDER BY` combined with `LIMIT`) -- this function itself stays
  # agnostic to which.
  #
  # Prefers `engine_module.fetch/3` (the whole `query` too) when the
  # engine implements it, falling back to `fetch/2` otherwise --
  # `Scry.Core.EngineBehaviour`'s own moduledoc has the full pushdown
  # contract and its own load-bearing safety invariant. Every engine
  # that only implements `fetch/2` is completely unaffected: `function_
  # exported?/3` is `false` for it, so this always takes the `fetch/2`
  # branch, byte-identical to before `fetch/3` existed.
  defp fetch_lazy(engine_module, conn, source, query) do
    result =
      if function_exported?(engine_module, :fetch, 3) do
        engine_module.fetch(conn, source, query)
      else
        engine_module.fetch(conn, source)
      end

    with {:ok, enumerable} <- result do
      {:ok, Cursor.new(enumerable)}
    end
  end

  # A `LIMIT`-less, `ORDER BY`/`DISTINCT`/window-free plain query with no
  # nested `SELECT` anywhere in `select` -- same eligibility `run_plain_
  # streaming/7` below already has, narrowed by the two conditions that
  # make chunked parallelism actually safe here (`run/6`'s own dispatch
  # decides between the two): no `LIMIT` to enforce (partitioning into
  # chunks processed independently means every chunk gets fully
  # processed regardless of whether an early one already had enough
  # rows -- strictly *more* work than the streaming path's own early
  # stop, never less, so a `LIMIT`-bound query keeps using that instead);
  # no nested query in `select` (a nested `SELECT` re-enters `Executor.
  # run/3` -- `run_any/6` -- once per surviving row; doing that inside an
  # already-parallel worker would let every worker's every row spawn a
  # further parallel fan-out with no shared concurrency cap `Scry.Core.
  # TaskSupervisor` enforces, unbounded process growth with query
  # nesting depth -- excluded entirely rather than reasoning about which
  # nested shapes might be safe enough).
  #
  # Splits the fetch `Cursor` into batches (`process_chunks_parallel/4`,
  # shared with the streaming-aggregation path above), filters and
  # projects each batch independently across a bounded worker pool using
  # the *exact same* per-row `matches_all?/4`/`project/8` functions
  # `run_plain/8` below already has (`filter_and_project_chunk/8`) --
  # behavior stays identical by construction, only the iteration
  # strategy differs -- then concatenates each batch's own already-
  # filtered/projected row list back together in fetch order (`ordered:
  # true` on the async stream, same guarantee the aggregation path
  # relies on) before `paginate/3` applies whatever `OFFSET` the query
  # still has (no `LIMIT`, by construction, but an `OFFSET`-only query is
  # a real, legitimate shape this path still needs to handle).
  defp run_plain_parallel(query, own_name, scope, params, with_bindings, engine_module, conn) do
    with {:ok, cursor} <- fetch_rows(query, scope, params, with_bindings, engine_module, conn) do
      # A fetch-level failure (an unknown source, say) surfaces eagerly
      # above, matching every other path's own convention -- but the
      # parallel dispatch/row-processing itself (where a `QueryError` or
      # a hard aggregate/cast error can originate, `filter_and_project_
      # chunk/8`'s own doc has the exact cases) must stay deferred until
      # a caller actually pulls from the returned `Cursor`, the same
      # "lazily-discovered failure never surfaces from `run/4` itself"
      # contract `run_plain_streaming/7` already has -- `Stream.
      # resource/3`'s own `start_fun`/`next_fun` don't run at all until
      # the stream is first reduced, so wrapping the whole computation
      # in one is what defers it, not an incidental side effect.
      stream =
        Stream.resource(
          fn -> :pending end,
          fn
            :pending ->
              chunk_fun =
                &filter_and_project_chunk(
                  &1,
                  query,
                  own_name,
                  scope,
                  params,
                  with_bindings,
                  engine_module,
                  conn
                )

              rows =
                cursor
                |> process_chunks_parallel(chunk_fun, &prepend_chunk/2, [])
                |> Enum.reverse()
                |> Enum.concat()
                |> paginate(query.limit, query.offset)

              {rows, :done}

            :done ->
              {:halt, :done}
          end,
          fn _state -> :ok end
        )

      {:ok, Cursor.new(stream)}
    end
  end

  defp select_has_nested_query?(select), do: Enum.any?(select, &match?(%Query{}, &1))

  # Real, measured (not assumed) gate on `run_plain_parallel/7`
  # eligibility: a `select` made only of bare field references is
  # *cheaper* through `run_plain_streaming/7` than through the parallel
  # path, since the parallel path still has to copy every matching row
  # into a worker's mailbox and back out again, and that copy cost
  # dwarfs a bare field access's own near-zero per-row compute -- +25%
  # to +35% slower, measured directly on 200K/1M-row tables, at every
  # chunk size tried (not a tuning artifact). A `select` with at least
  # one real function call (`json(...)`, `cast`/`string`, ...) is a
  # different story: the per-row compute is now large enough to be
  # worth parallelizing even after paying the same copy cost -- a
  # measured 1.4-1.5x speedup on the same tables with a `json(...)`
  # decode + nested-path projection in `select`. `select_has_call?/1`
  # is the cheap, purely-structural proxy for "expensive enough to be
  # worth it": not a guarantee (`upper(name)` is a call but still
  # cheap; a callless-but-otherwise-costly projection isn't caught
  # either), but it matches the measured boundary directly and needs no
  # runtime cost model to compute.
  defp select_has_call?(select), do: Enum.any?(select, &body_item_has_call?/1)

  defp body_item_has_call?({:computed, _alias, expr}), do: expr_has_call?(expr)
  defp body_item_has_call?(_other), do: false

  defp expr_has_call?({:call, _name, _args}), do: true
  defp expr_has_call?({:distinct, expr}), do: expr_has_call?(expr)
  defp expr_has_call?({:dot, base, _path}), do: expr_has_call?(base)

  defp expr_has_call?({:arith, _op, l, r}),
    do: expr_has_call?(l) or expr_has_call?(r)

  defp expr_has_call?({:when, clauses, else_expr}) do
    Enum.any?(clauses, fn {_predicate, expr} -> expr_has_call?(expr) end) or
      expr_has_call?(else_expr)
  end

  # A window-wrapped call is unreachable here in practice (`run/6`'s
  # own dispatch already requires `windows == []` before this path is
  # even considered) -- `true`, not `false`, since it's still a real
  # call under the hood, matching this helper's "any call anywhere"
  # contract rather than special-casing a branch that can't be hit.
  defp expr_has_call?({:window, _call, _partition_by, _order_bys, _frame}), do: true

  defp expr_has_call?(_other), do: false

  defp prepend_chunk(acc, chunk_rows), do: [chunk_rows | acc]

  # Pure -- no cursor, no shared state -- one worker's own share of the
  # source, filtered and projected exactly the way `plain_stream_row/5`
  # already does one row at a time; a `:skip` (`REQUIRED`-dropped
  # nested-query row -- never reached in practice here, since queries
  # with a nested `SELECT` never dispatch to this path at all, but
  # `project/8`'s own return shape still has the case) or a filtered-out
  # row is simply omitted, not emitted as a hole; `project/8`'s own
  # `{:error, reason}` (its `{:variant, _}` clause, today's only case)
  # raises the exact same `QueryError` the streaming path already does,
  # propagated through the owning worker task and re-raised in the
  # calling process by `process_chunks_parallel/4`'s own error handling.
  defp filter_and_project_chunk(
         rows,
         query,
         own_name,
         scope,
         params,
         with_bindings,
         engine_module,
         conn
       ) do
    Enum.flat_map(rows, fn row ->
      if matches_all?(row, query.wheres, scope, params) do
        case project(
               row,
               query.select,
               own_name,
               scope,
               params,
               with_bindings,
               engine_module,
               conn
             ) do
          {:ok, projected} -> [projected]
          :skip -> []
          {:error, reason} -> raise(QueryError, reason: reason)
        end
      else
        []
      end
    end)
  end

  # The genuinely lazy plain-query path -- reached only when nothing
  # downstream needs the whole row set materialized first (`run/6`'s own
  # dispatch: no window call, no real `ORDER BY`, no `DISTINCT`). Returns
  # `{:ok, Cursor.t()}` directly, built via `Stream.resource/3` over the
  # fetch cursor -- *not* a recursive accumulator returning a finished
  # list, so nothing downstream of this function ever forces the whole
  # row set into memory either; a caller pulling just a few rows (or a
  # `LIMIT`-bound query, enforced below as part of the stream itself)
  # genuinely only pulls that many rows from the underlying source.
  # Reuses the *exact same* per-row `matches_all?/4`/`project/8`
  # functions the eager `run_plain/8` path already has below -- behavior
  # stays identical by construction, only the iteration strategy
  # differs. `Stream.resource/3`'s own `after_fun` (`Cursor.close/1` on
  # the source cursor) is *guaranteed* to run whether the stream reaches
  # its own natural end, is halted early (`LIMIT` satisfied, or the
  # caller simply stops pulling), or an exception propagates out of
  # `next_fun` -- confirmed against Elixir's own documented `Stream.
  # resource/3` contract, the same guarantee `Scry.Core.Cursor`'s own
  # moduledoc already relies on for `close/1` itself.
  defp run_plain_streaming(query, own_name, scope, params, with_bindings, engine_module, conn) do
    with {:ok, source_cursor} <-
           fetch_rows(query, scope, params, with_bindings, engine_module, conn) do
      ctx = {query, own_name, scope, params, with_bindings, engine_module, conn}

      stream =
        Stream.resource(
          fn -> {source_cursor, query.offset || 0, 0} end,
          fn state -> plain_stream_step(state, ctx) end,
          fn {cursor, _to_skip, _emitted} -> Cursor.close(cursor) end
        )

      {:ok, Cursor.new(stream)}
    end
  end

  # `Stream.resource/3`'s own `next_fun` -- `{[row], new_state}` to emit
  # exactly one row and continue, or `{:halt, state}` to stop. Loops
  # internally (an ordinary recursive call, not itself re-entering
  # `Stream.resource`) past a row failing `WHERE` or a `:skip` (`REQUIRED`
  # -dropped) projection, since a single call has to return *something*
  # -- there's no "try again" signal back to `Stream.resource` itself.
  defp plain_stream_step({cursor, to_skip, emitted}, {query, _, _, _, _, _, _})
       when query.limit != nil and emitted >= query.limit do
    {:halt, {cursor, to_skip, emitted}}
  end

  defp plain_stream_step({cursor, to_skip, emitted}, ctx) do
    case Cursor.next(cursor) do
      :done -> {:halt, {cursor, to_skip, emitted}}
      {:ok, row, cursor2} -> plain_stream_row(row, cursor2, to_skip, emitted, ctx)
    end
  end

  defp plain_stream_row(
         row,
         cursor2,
         to_skip,
         emitted,
         {query, own_name, scope, params, with_bindings, engine_module, conn} = ctx
       ) do
    if matches_all?(row, query.wheres, scope, params) do
      row
      |> project(query.select, own_name, scope, params, with_bindings, engine_module, conn)
      |> plain_stream_projected(cursor2, to_skip, emitted, ctx)
    else
      plain_stream_step({cursor2, to_skip, emitted}, ctx)
    end
  end

  defp plain_stream_projected({:ok, _projected}, cursor2, to_skip, emitted, ctx)
       when to_skip > 0,
       do: plain_stream_step({cursor2, to_skip - 1, emitted}, ctx)

  defp plain_stream_projected({:ok, projected}, cursor2, 0, emitted, _ctx),
    do: {[projected], {cursor2, 0, emitted + 1}}

  defp plain_stream_projected(:skip, cursor2, to_skip, emitted, ctx),
    do: plain_stream_step({cursor2, to_skip, emitted}, ctx)

  # `project/8`'s own `{:error, reason}` (today: only its `{:variant, _}`
  # clause) has no room in `next_fun`'s own `{[row], state} | {:halt,
  # state}` contract -- raised instead, `QueryError`'s own moduledoc has
  # the full "why a raise, not a tuple, for this one case" reasoning.
  # `Stream.resource/3`'s own `after_fun` still runs (see this function's
  # own caller, above) -- the source cursor gets closed either way.
  defp plain_stream_projected({:error, reason}, _cursor2, _to_skip, _emitted, _ctx),
    do: raise(QueryError, reason: reason)

  # Today's ungrouped path, unchanged for a query with no window
  # function anywhere in its own `select` -- `collect_and_rewrite_
  # window_calls/1` returns `{[], query.select}` in that case (confirmed
  # by construction: nothing to collect, nothing to rewrite), so
  # `select`/`filtered` below are exactly `query.select`/`filtered` from
  # the caller, byte-identical to this module's own pre-existing
  # behavior. When there *is* a window function, each one's own value
  # list is computed once here (`compute_window_values/4`, this
  # module's own "Window functions" section below), then folded onto
  # `filtered` as an ordinary per-row field under a synthetic key
  # (`window_key/1`) -- the *rewritten* `select` references that key via
  # an ordinary `{:field, ...}`, so `project_all` below needs no
  # awareness of window functions at all; it's already resolving what
  # looks like any other computed field.
  defp run_plain(query, filtered, own_name, scope, params, with_bindings, engine_module, conn) do
    {windows, select} = collect_and_rewrite_window_calls(query.select)
    augmented = augment_with_window_values(filtered, windows, scope, params)
    sorted = sort_rows(augmented, query.order_bys, scope)

    with {:ok, projected} <-
           project_all(
             sorted,
             select,
             own_name,
             scope,
             params,
             with_bindings,
             engine_module,
             conn
           ) do
      {:ok,
       projected
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  # ---- Bounded top-K streaming (real ORDER BY + a real LIMIT) -------------
  #
  # `run/6`'s own dispatch above reaches this only for a real `ORDER BY`
  # *with* a real `LIMIT` -- no window function, no `DISTINCT` (both still
  # force `run_plain/8`'s own full materialize-then-sort path, unchanged),
  # and no `REQUIRED` nested `SELECT` directly in `select`
  # (`select_can_skip_rows?/1` below) -- a row that `project_item/8` might
  # still `:skip` can't safely be counted toward the bounded buffer's own
  # capacity ahead of time, so that combination keeps using the eager path
  # too, honestly narrower rather than silently wrong.
  #
  # The actual bound: rather than materializing every filtered row before
  # sorting (`run_plain/8`'s own `sort_rows/3`, `O(n)` memory regardless of
  # `LIMIT`), this keeps only the `limit + offset` *best-so-far* rows in
  # memory at any point during the scan -- `O(limit + offset)`, not `O(n)`
  # -- the same memory-boundedness goal `run_plain_streaming/7`/`run_
  # grouped_streaming/7` already deliver for their own cases. Every row
  # still has to be *pulled* from the source and compared (there's no way
  # to know a later row won't outrank a currently-buffered one without
  # seeing it), so this doesn't save *time* the way an early `LIMIT`-only
  # stop does -- only memory, matching this whole feature's own "memory
  # boundedness, not speed" goal.
  #
  # Reuses `sorts_before?/4` (`sort_rows/3`'s own comparator) directly,
  # not a separate ordering implementation -- the buffer's own final
  # content is provably identical to `Enum.sort/2` truncated to `limit +
  # offset` rows, since both are defined by the same total order over the
  # same predicate; only *how* that result is reached (bounded insertion
  # vs. a full sort) differs.
  defp select_can_skip_rows?(select), do: Enum.any?(select, &match?(%Query{required: true}, &1))

  defp run_topk_streaming(query, own_name, scope, params, with_bindings, engine_module, conn) do
    k = (query.limit || 0) + (query.offset || 0)

    with {:ok, source_cursor} <-
           fetch_rows(query, scope, params, with_bindings, engine_module, conn),
         {:ok, top_rows} <- accumulate_topk(source_cursor, query, k, scope, params, []),
         {:ok, projected} <-
           project_all(
             top_rows,
             query.select,
             own_name,
             scope,
             params,
             with_bindings,
             engine_module,
             conn
           ) do
      {:ok, paginate(projected, query.limit, query.offset)}
    end
  end

  # `k == 0` (a real `LIMIT 0`) needs no buffering, no `WHERE` evaluation,
  # and no comparator at all -- still drains the cursor (so a `Stream.
  # resource/3`-backed source's own `after_fun` still runs on natural
  # exhaustion, same guarantee every other pull in this module already
  # has), just never keeps anything.
  defp accumulate_topk(cursor, _query, 0, _scope, _params, _buffer), do: drain(cursor)

  defp accumulate_topk(cursor, query, k, scope, params, buffer) do
    case Cursor.next(cursor) do
      :done ->
        {:ok, buffer}

      {:ok, row, cursor2} ->
        if matches_all?(row, query.wheres, scope, params) do
          new_buffer = insert_topk(buffer, row, k, query.order_bys, scope)
          accumulate_topk(cursor2, query, k, scope, params, new_buffer)
        else
          accumulate_topk(cursor2, query, k, scope, params, buffer)
        end
    end
  rescue
    e ->
      Cursor.close(cursor)
      reraise e, __STACKTRACE__
  end

  defp drain(cursor) do
    case Cursor.next(cursor) do
      :done -> {:ok, []}
      {:ok, _row, cursor2} -> drain(cursor2)
    end
  end

  defp insert_topk(buffer, row, k, order_bys, scope) when length(buffer) < k,
    do: insert_sorted(buffer, row, order_bys, scope)

  defp insert_topk(buffer, row, _k, order_bys, scope) do
    worst = List.last(buffer)

    if sorts_before?(row, worst, order_bys, scope) do
      buffer |> List.delete_at(-1) |> insert_sorted(row, order_bys, scope)
    else
      buffer
    end
  end

  defp insert_sorted(buffer, row, order_bys, scope) do
    {before, rest} = Enum.split_while(buffer, &sorts_before?(&1, row, order_bys, scope))
    before ++ [row | rest]
  end

  # ---- Streaming aggregation (group_mode: :plain only) --------------------
  #
  # `sum`/`avg`/`count`/`min`/`max` (`count(distinct ...)` included) are
  # all mathematically computable one row at a time -- a running total per
  # group, never a kept list of member rows -- unlike `percentile` (needs
  # every value, sorted; no single-pass algorithm exists for exact
  # percentile) or `stddev*`/`var*` (this module's own existing two-pass
  # computation would need Welford's algorithm to go single-pass, real
  # numerical-stability work deliberately not attempted here). This
  # section covers only the common, realistic shape -- a streaming-capable
  # aggregate call as the *entire* value of a `{:computed, ...}` select
  # item, or as an entire side of a `HAVING` comparison -- never nested
  # inside arithmetic/a cast/a `WHEN` (`avg(x) * 2`, say); anything wider
  # falls back to `run_grouped/6` below, unchanged. `ROLLUP`/`CUBE`
  # (multiple simultaneous per-level accumulators, one streaming pass)
  # are real, more complex, deliberately deferred -- `group_mode: :plain`
  # only, checked by this section's own caller in `run/6`.
  @streaming_capable_aggregate_names ~w(sum avg count min max)

  # `{:ok, [{name, args}]}` -- the distinct aggregate calls this query's
  # own select/havings actually need streamed -- or `:not_streamable`,
  # the safe "fall back to the fully eager path" answer for anything
  # wider than the shape this section covers (checked above).
  @spec streaming_aggregate_plan(Query.t()) :: {:ok, [{String.t(), [term()]}]} | :not_streamable
  defp streaming_aggregate_plan(query) do
    with {:ok, select_calls} <- streaming_select_calls(query.select),
         {:ok, having_calls} <- streaming_having_calls(query.havings) do
      {:ok, Enum.uniq(select_calls ++ having_calls)}
    end
  end

  defp streaming_select_calls(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case streaming_body_item_calls(item) do
        {:ok, calls} -> {:cont, {:ok, calls ++ acc}}
        :not_streamable -> {:halt, :not_streamable}
      end
    end)
  end

  defp streaming_body_item_calls({:field, _path}), do: {:ok, []}

  defp streaming_body_item_calls({:computed, _alias, {:call, name, args}})
       when name in @streaming_capable_aggregate_names,
       do: {:ok, [{name, args}]}

  defp streaming_body_item_calls({:computed, _alias, expr}) do
    if expr_has_aggregate_call?(expr), do: :not_streamable, else: {:ok, []}
  end

  # A nested `SELECT`/`{:field, path, condition}` (`IF $param`)/
  # `{:variant, _}` body item -- `project_group_item/8`'s own catch-all
  # (below) already unconditionally rejects all three inside a grouped
  # `select`, so this is the same "not supported in a grouped select"
  # answer, just decided before ever fetching a single row instead of
  # after collecting every group's own member rows for nothing.
  defp streaming_body_item_calls(_other), do: :not_streamable

  defp streaming_having_calls(havings) do
    Enum.reduce_while(havings, {:ok, []}, fn pred, {:ok, acc} ->
      case streaming_predicate_calls(pred) do
        {:ok, calls} -> {:cont, {:ok, calls ++ acc}}
        :not_streamable -> {:halt, :not_streamable}
      end
    end)
  end

  defp streaming_predicate_calls({:cmp, _op, lhs, rhs}) do
    combine_streaming(streaming_side_calls(lhs), streaming_side_calls(rhs))
  end

  defp streaming_predicate_calls({:in, lhs, values}) when is_list(values) do
    Enum.reduce_while(values, streaming_side_calls(lhs), fn value, acc ->
      case combine_streaming(acc, streaming_side_calls(value)) do
        {:ok, _} = ok -> {:cont, ok}
        :not_streamable -> {:halt, :not_streamable}
      end
    end)
  end

  defp streaming_predicate_calls({:in, lhs, list_expr}),
    do: combine_streaming(streaming_side_calls(lhs), streaming_side_calls(list_expr))

  defp streaming_predicate_calls({:and, l, r}),
    do: combine_streaming(streaming_predicate_calls(l), streaming_predicate_calls(r))

  defp streaming_predicate_calls({:or, l, r}),
    do: combine_streaming(streaming_predicate_calls(l), streaming_predicate_calls(r))

  defp streaming_predicate_calls({:not, p}), do: streaming_predicate_calls(p)

  defp combine_streaming({:ok, a}, {:ok, b}), do: {:ok, a ++ b}
  defp combine_streaming(_a, _b), do: :not_streamable

  # A predicate's own `lhs`/`rhs` (`Query.predicate()`'s own narrower
  # shapes, not a full `expr()`) -- a bare path (`lhs`'s own `[String.
  # t()]` shape) or a literal never has a call in it at all; a direct
  # streaming-capable aggregate call is exactly what this whole section
  # exists to handle; anything else defers to `expr_has_aggregate_call?/1`
  # (the same walker `aggregate_query?/1` itself already uses) to decide
  # whether it's aggregate-free (fine, representative-evaluated) or has
  # one buried inside something wider (not streamable).
  defp streaming_side_calls(path) when is_list(path), do: {:ok, []}
  defp streaming_side_calls({:literal, _value}), do: {:ok, []}

  defp streaming_side_calls({:call, name, args})
       when name in @streaming_capable_aggregate_names,
       do: {:ok, [{name, args}]}

  defp streaming_side_calls({:call, _name, _args}), do: :not_streamable

  defp streaming_side_calls({:dot, base, _path}) do
    if expr_has_aggregate_call?(base), do: :not_streamable, else: {:ok, []}
  end

  defp streaming_side_calls(expr) do
    if expr_has_aggregate_call?(expr), do: :not_streamable, else: {:ok, []}
  end

  # Splits the fetch `Cursor` into fixed-size batches (`Cursor.take/2`,
  # `parallel_chunk_size/0`) and folds each batch's own row processing
  # (`matches_all?/4` + per-row aggregate updates, `update_agg/5` below
  # -- identical logic to a single row at a time, just applied to a
  # list) across a bounded pool of supervised worker tasks
  # (`Scry.Core.TaskSupervisor`, `parallel_max_concurrency/0`), merging
  # each batch's own partial `{groups, order}` state into the running
  # combined result *in fetch order* (`merge_group_state/2`) -- so the
  # final result (representative row per group, first-appearance order,
  # every running total) is byte-identical to what processing every row
  # one at a time, in a single process, would produce, regardless of
  # how many workers actually ran or in what order they finished
  # (`ordered: true` on the async stream is exactly what guarantees
  # this: results are consumed in submission order, never completion
  # order). `groups` is a plain map (`group_key => %{representative:
  # row, aggs: %{{name, args} => acc}}`); `order` tracks first-
  # appearance order the same way `group_rows/3`'s own manual reduce
  # already does, for the same "well-defined even when not required"
  # determinism this module's `sort_rows/3` comment already documents
  # elsewhere. Peak memory is `O(distinct groups)` plus whatever's
  # in flight across the worker pool (`O(parallel_chunk_size *
  # parallel_max_concurrency)`), not `O(matching rows)` -- a real,
  # deliberate widening from the single-process path's own `O(distinct
  # groups)` alone, the cost of genuine parallelism.
  #
  # `Task.Supervisor.async_stream_nolink/4` (not plain `Task.async_
  # stream/3`, and not a linked `Task.async/1`) is load-bearing, not a
  # style choice -- verified directly (a real crashing task, not
  # assumed): a *linked* task's own crash sends an uncatchable `EXIT`
  # signal that kills the calling process outright, which would turn a
  # query's own hard aggregate-nil error (`raise_aggregate_nil_error/1`,
  # an ordinary, callers-can-rescue exception on the single-process
  # path) into an unrescuable crash of whatever process called
  # `Executor.run/4` -- a real behavior regression, not just an
  # implementation detail. `_nolink`, dispatched through `Scry.Core.
  # TaskSupervisor` (started by `Scry.Core.Application`), instead
  # reports a failed batch as an ordinary `{:exit, reason}` tuple this
  # module inspects and re-raises itself (`reduce_chunk_result/3`) --
  # an ordinary, catchable exception in the calling process, exactly
  # matching today's single-process behavior; confirmed directly (a
  # real crashing batch, mid-stream, with more batches still queued)
  # that the remaining, not-yet-started batches never run once that
  # happens (`Enum.reduce_while/3`'s own `{:halt, ...}` propagates back
  # through the async stream and stops it from submitting more work),
  # and that the source `Cursor`'s own cleanup (`Stream.resource/3`'s
  # `after_fun`, inside `chunk_stream/1` below) still runs either way.
  defp run_grouped_streaming(query, plan, scope, params, with_bindings, engine_module, conn) do
    with {:ok, rows} <-
           grouped_base_rows_streaming(
             query,
             plan,
             scope,
             params,
             with_bindings,
             engine_module,
             conn
           ) do
      {:ok,
       rows
       |> sort_rows(query.order_bys, [])
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  # The `HAVING`-filtered, finalized group rows -- before `ORDER BY`/
  # `DISTINCT`/`LIMIT`+`OFFSET` -- same "factored out for `run_grouped_
  # with_windows/6` to reuse" reasoning `grouped_base_rows/6` above has,
  # for the streaming-aggregation path specifically.
  defp grouped_base_rows_streaming(query, plan, scope, params, with_bindings, engine_module, conn) do
    with {:ok, source_cursor} <-
           fetch_rows(query, scope, params, with_bindings, engine_module, conn),
         {:ok, groups, order} <-
           accumulate_groups_parallel(source_cursor, query, plan, scope, params) do
      rows =
        for key <- order,
            group_state = Map.fetch!(groups, key),
            having_matches_streaming?(query.havings, group_state, scope, params) do
          finalize_grouped_row(query, group_state, scope, params)
        end

      {:ok, rows}
    end
  end

  # Overridable via `config :scry_core, parallel_chunk_size: n` /
  # `parallel_max_concurrency: n` -- exists so tests can force real
  # multi-batch, multi-worker execution without needing millions of
  # rows to exceed the real-world default, the same reasoning `scry_
  # engine_exqlite`'s own configurable `chunk_size` already has.
  @default_parallel_chunk_size 5_000
  defp parallel_chunk_size,
    do: Application.get_env(:scry_core, :parallel_chunk_size, @default_parallel_chunk_size)

  defp parallel_max_concurrency,
    do: Application.get_env(:scry_core, :parallel_max_concurrency, System.schedulers_online())

  defp accumulate_groups_parallel(cursor, query, plan, scope, params) do
    {groups, order} =
      process_chunks_parallel(
        cursor,
        &accumulate_chunk(&1, query, plan, scope, params),
        &merge_group_state/2,
        {%{}, []}
      )

    {groups2, order2} = ensure_flat_group(query.group_bys, plan, groups, order)
    {:ok, groups2, order2}
  end

  # The shared runner behind every parallel-chunked path in this module
  # (streaming aggregation above; the parallel plain `WHERE`+projection
  # path below) -- fetches nothing and knows nothing about aggregates
  # or projection itself, just: split `cursor` into fixed-size batches,
  # process each independently on a bounded pool of supervised worker
  # tasks, and fold results back together *in fetch order* via
  # `merge_fun`, starting from `initial_acc`. `chunk_fun` (a batch's own
  # row list -> that batch's own partial result) and `merge_fun` (an
  # accumulated partial result + one more batch's own partial result ->
  # the combined partial result) are the only two things that differ
  # between callers; everything else -- batching, supervision,
  # ordering, cleanup, error propagation -- is identical regardless of
  # what's actually being computed.
  #
  # `Task.Supervisor.async_stream_nolink/4` (not plain `Task.async_
  # stream/3`, and not a linked `Task.async/1`) is load-bearing, not a
  # style choice -- verified directly (a real crashing task, not
  # assumed): a *linked* task's own crash sends an uncatchable `EXIT`
  # signal that kills the calling process outright, which would turn an
  # ordinary, callers-can-rescue exception on the single-process path
  # (a hard aggregate-nil error, say) into an unrescuable crash of
  # whatever process called `Executor.run/4` -- a real behavior
  # regression, not just an implementation detail. `_nolink`, dispatched
  # through `Scry.Core.TaskSupervisor` (started by `Scry.Core.
  # Application`), instead reports a failed batch as an ordinary
  # `{:exit, reason}` tuple this module inspects and re-raises itself
  # (`reduce_chunk_result/3`) -- an ordinary, catchable exception in the
  # calling process, exactly matching today's single-process behavior;
  # confirmed directly (a real crashing batch, mid-stream, with more
  # batches still queued) that the remaining, not-yet-started batches
  # never run once that happens (`Enum.reduce_while/3`'s own `{:halt,
  # ...}` propagates back through the async stream and stops it from
  # submitting more work), and that the source `Cursor`'s own cleanup
  # (`Stream.resource/3`'s `after_fun`, inside `chunk_stream/1` below)
  # still runs either way. `ordered: true` is what guarantees results
  # are folded into `merge_fun` in submission (fetch) order, never
  # completion order -- callers rely on this for byte-identical output
  # to a single-process, one-batch-at-a-time run, regardless of how
  # many workers actually ran or in what order they finished. Peak
  # memory is whatever `initial_acc`/its merged form costs, plus
  # `O(parallel_chunk_size * parallel_max_concurrency)` in flight across
  # the worker pool -- a real, deliberate widening from a fully
  # single-process streaming path's own tighter bound, the cost of
  # genuine parallelism.
  defp process_chunks_parallel(cursor, chunk_fun, merge_fun, initial_acc) do
    Scry.Core.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      chunk_stream(cursor),
      chunk_fun,
      ordered: true,
      max_concurrency: parallel_max_concurrency()
    )
    |> Enum.reduce_while(initial_acc, &reduce_chunk_result(&1, &2, merge_fun))
  end

  # `Stream.resource/3`, not `Stream.unfold/2` -- its own `after_fun`
  # (`Cursor.close/1`) is what guarantees the source cursor (and
  # whatever real connection/statement it wraps) gets cleaned up
  # correctly when the stream stops early, the exact same guarantee
  # `Cursor` itself relies on and this module's own plain streaming
  # path (`run_plain_streaming/7`) already uses -- verified directly
  # this still holds through `Task.Supervisor.async_stream_nolink/4`
  # too, not assumed just because it held for `Cursor` alone.
  defp chunk_stream(cursor) do
    Stream.resource(
      fn -> cursor end,
      fn cursor ->
        case Cursor.take(cursor, parallel_chunk_size()) do
          {[], cursor2} -> {:halt, cursor2}
          {chunk, cursor2} -> {[chunk], cursor2}
        end
      end,
      fn cursor -> Cursor.close(cursor) end
    )
  end

  defp reduce_chunk_result({:ok, chunk_result}, acc, merge_fun),
    do: {:cont, merge_fun.(acc, chunk_result)}

  # `Task.Supervised`'s own `exit_reason/3` (the real source of the
  # `{:exit, reason}` tuple `async_stream_nolink` hands back) shapes
  # `reason` differently per *original* failure kind -- `{value,
  # stacktrace}` for `:error` (an explicit `raise`, but just as often a
  # genuine BEAM-level runtime error like a failed function-clause
  # match, which is *not* pre-built into an exception struct the way an
  # explicit `raise SomeException` is -- confirmed directly, not
  # assumed: a real `no function clause matching` crash comes back as
  # `{:function_clause, stacktrace}`, a bare atom, not a struct, which
  # an earlier `is_exception(exception)`-guarded version of this clause
  # silently failed to match, falling through to a bare `exit/1` that
  # crashed the *calling* process uncatchably instead of raising an
  # ordinary, rescuable exception in it -- exactly the regression this
  # whole mechanism exists to prevent), `{{:nocatch, value}, stacktrace}`
  # for an uncaught `throw`, or a bare `reason` (no stacktrace) for an
  # explicit `exit/1`. `:erlang.raise/3` with the reconstructed original
  # kind reproduces exactly what would have happened had the same code
  # run un-`Task`-wrapped in the calling process -- ordinary `rescue`/
  # `catch` (including `assert_raise`) already normalizes a raw runtime
  # reason like `:function_clause` into its `FunctionClauseError` form
  # at the point something actually catches it, the same as it always
  # does for a directly-raised error, so no manual normalization is
  # needed here.
  defp reduce_chunk_result({:exit, {{:nocatch, value}, stacktrace}}, _acc, _merge_fun),
    do: :erlang.raise(:throw, value, stacktrace)

  defp reduce_chunk_result({:exit, {reason, stacktrace}}, _acc, _merge_fun)
       when is_list(stacktrace),
       do: :erlang.raise(:error, reason, stacktrace)

  defp reduce_chunk_result({:exit, reason}, _acc, _merge_fun), do: exit(reason)

  # `group_rows/3`'s own `group_rows(rows, [], _scope), do: [rows]` --
  # a *flat* aggregate (no explicit `GROUP BY` at all) always collapses
  # to exactly one output row, even over zero matching rows (`count = 0`,
  # `sum`/`avg`/`min`/`max` = `nil` -- this module's own moduledoc's own
  # "well-defined output row" framing) -- a real `GROUP BY` with zero
  # matching rows correctly stays zero output rows instead (SQL
  # convention; only the flat-aggregate case gets this treatment).
  # `accumulate_chunk/5` never creates a group for a source with zero
  # surviving rows at all, so this seeds exactly one, in its own already-
  # empty initial accumulator state, if (and only if) `group_bys == []`
  # and nothing created one already.
  defp ensure_flat_group([], plan, groups, _order) when map_size(groups) == 0 do
    empty_state = %{
      representative: %{},
      aggs: Map.new(plan, fn {name, args} -> {{name, args}, init_agg(name, args)} end)
    }

    {%{[] => empty_state}, [[]]}
  end

  defp ensure_flat_group(_group_bys, _plan, groups, order), do: {groups, order}

  # Pure -- no cursor, no shared state -- so many of these can run at
  # once, one per worker task, with nothing to coordinate until their
  # own results get merged back in `merge_group_state/2`. `order`
  # comes back in this chunk's own first-appearance order (forward, not
  # reversed) -- `merge_group_state/2` relies on that directly.
  defp accumulate_chunk(rows, query, plan, scope, params) do
    {groups, reversed_order} =
      Enum.reduce(rows, {%{}, []}, fn row, {groups, order} ->
        if matches_all?(row, query.wheres, scope, params) do
          key = Enum.map(query.group_bys, &get_path(row, scope, &1))

          case Map.fetch(groups, key) do
            {:ok, state} ->
              {Map.put(groups, key, update_group(state, plan, row, scope, params)), order}

            :error ->
              {Map.put(groups, key, new_group(row, plan, scope, params)), [key | order]}
          end
        else
          {groups, order}
        end
      end)

    {groups, Enum.reverse(reversed_order)}
  end

  # Folds one chunk's own `{groups, order}` into the combined result so
  # far, preserving true first-appearance order across chunk boundaries
  # (`order_acc` is already every earlier chunk's own keys, in order;
  # any genuinely new key from this chunk is appended after it, in this
  # chunk's own relative order) and "whichever chunk saw this group
  # first keeps the representative row" (`merge_group/3` always keeps
  # `acc`'s own representative over the new chunk's) -- both exactly
  # matching what a single process working through the same rows, one
  # at a time, in the same order, would have produced.
  defp merge_group_state({groups_acc, order_acc}, {groups_new, order_new}) do
    {merged_groups, reversed_new_keys} =
      Enum.reduce(order_new, {groups_acc, []}, fn key, {groups, new_keys} ->
        new_state = Map.fetch!(groups_new, key)

        case Map.fetch(groups, key) do
          {:ok, existing_state} ->
            {Map.put(groups, key, merge_group(existing_state, new_state)), new_keys}

          :error ->
            {Map.put(groups, key, new_state), [key | new_keys]}
        end
      end)

    {merged_groups, order_acc ++ Enum.reverse(reversed_new_keys)}
  end

  defp merge_group(%{representative: rep, aggs: aggs1}, %{aggs: aggs2}) do
    merged_aggs =
      Map.new(aggs1, fn {{name, _args} = key, acc1} ->
        {key, merge_agg(acc1, Map.fetch!(aggs2, key), name)}
      end)

    %{representative: rep, aggs: merged_aggs}
  end

  defp merge_agg(count1, count2, "count") when is_integer(count1) and is_integer(count2),
    do: count1 + count2

  defp merge_agg(%MapSet{} = set1, %MapSet{} = set2, "count"), do: MapSet.union(set1, set2)

  defp merge_agg({sum1, count1}, {sum2, count2}, "avg"),
    do: {merge_sum(sum1, sum2), count1 + count2}

  defp merge_agg(acc1, acc2, "sum"), do: merge_sum(acc1, acc2)
  defp merge_agg(acc1, acc2, "min"), do: merge_extreme(acc1, acc2, &pick_min/2)
  defp merge_agg(acc1, acc2, "max"), do: merge_extreme(acc1, acc2, &pick_max/2)

  defp merge_sum(:empty, acc2), do: acc2
  defp merge_sum(acc1, :empty), do: acc1
  defp merge_sum(acc1, acc2), do: Rational.add(acc1, acc2)

  defp merge_extreme(:empty, acc2, _picker), do: acc2
  defp merge_extreme(acc1, :empty, _picker), do: acc1
  defp merge_extreme(acc1, acc2, picker), do: picker.(acc1, acc2)

  defp new_group(row, plan, scope, params) do
    aggs =
      Map.new(plan, fn {name, args} ->
        {{name, args}, update_agg(init_agg(name, args), name, args, row, scope, params)}
      end)

    %{representative: row, aggs: aggs}
  end

  defp update_group(%{representative: rep, aggs: aggs}, plan, row, scope, params) do
    aggs2 =
      Map.new(plan, fn {name, args} ->
        {{name, args}, update_agg(Map.fetch!(aggs, {name, args}), name, args, row, scope, params)}
      end)

    %{representative: rep, aggs: aggs2}
  end

  defp init_agg("avg", _args), do: {:empty, 0}
  defp init_agg("count", [{:distinct, _arg}]), do: MapSet.new()
  defp init_agg("count", _args), do: 0
  defp init_agg(_name, _args), do: :empty

  defp update_agg(acc, "count", [{:distinct, arg}], row, scope, params) do
    value = resolve_rhs(arg, row, scope, params)
    if is_nil(value), do: raise_aggregate_nil_error("count(distinct ...)")
    MapSet.put(acc, value)
  end

  defp update_agg(acc, "count", [arg], row, scope, params) do
    value = resolve_rhs(arg, row, scope, params)
    if is_nil(value), do: raise_aggregate_nil_error("count(...)")
    acc + 1
  end

  defp update_agg({sum_acc, count}, "avg", [arg], row, scope, params) do
    value = resolve_rhs(arg, row, scope, params)
    if is_nil(value), do: raise_aggregate_nil_error("avg(...)")
    {add_to_running_sum(sum_acc, value), count + 1}
  end

  defp update_agg(acc, "sum", [arg], row, scope, params) do
    value = resolve_rhs(arg, row, scope, params)
    if is_nil(value), do: raise_aggregate_nil_error("sum(...)")
    add_to_running_sum(acc, value)
  end

  defp update_agg(acc, "min", [arg], row, scope, params) do
    value = resolve_rhs(arg, row, scope, params)
    if is_nil(value), do: raise_aggregate_nil_error("min(...)")
    if acc == :empty, do: value, else: pick_min(acc, value)
  end

  defp update_agg(acc, "max", [arg], row, scope, params) do
    value = resolve_rhs(arg, row, scope, params)
    if is_nil(value), do: raise_aggregate_nil_error("max(...)")
    if acc == :empty, do: value, else: pick_max(acc, value)
  end

  # Matches `eval_aggregate/5`'s own two catch-all error clauses exactly
  # -- `sum(distinct x)`/etc. (`distinct` is only ever valid inside
  # `count(distinct ...)`) and any streaming-capable aggregate called
  # with anything other than exactly one argument. Declared *after*
  # every real per-name clause above, same reasoning `eval_aggregate/5`
  # itself already documents for its own identically-ordered clauses.
  defp update_agg(_acc, name, [{:distinct, _arg}], _row, _scope, _params) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not #{name}(...)"
  end

  defp update_agg(_acc, name, args, _row, _scope, _params) do
    raise ArgumentError, "aggregate #{name}/1 expects exactly one argument, got #{length(args)}"
  end

  defp add_to_running_sum(:empty, value), do: value
  defp add_to_running_sum(existing, value), do: Rational.add(existing, value)

  # Matches `eval_aggregate/5`'s own nil-hard-error message exactly
  # (lang_spec.md's own "Aggregates over nullable fields hard-error the
  # same way" -- no silent nil-skipping, filter it out explicitly first).
  defp raise_aggregate_nil_error(call_text) do
    raise ArgumentError,
          "aggregate #{call_text} encountered a nil value -- lang_spec.md's own " <>
            "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
            "nil-skipping); filter it out explicitly first"
  end

  defp having_matches_streaming?(havings, group_state, scope, params),
    do: Enum.all?(havings, &eval_having_streaming?(&1, group_state, scope, params))

  # Mirrors `eval_predicate/4`'s own literal-`nil`-rhs exemption --
  # kept in parity with `eval_group_predicate/4`'s own identical clause,
  # the eager `HAVING` path's counterpart to this streaming one.
  defp eval_having_streaming?({:cmp, op, lhs, nil}, group_state, scope, params),
    do: compare(op, finalize_side(lhs, group_state, scope, params), nil)

  defp eval_having_streaming?({:cmp, op, lhs, rhs}, group_state, scope, params) do
    left = finalize_side(lhs, group_state, scope, params)

    case finalize_side(rhs, group_state, scope, params) do
      _ when is_nil(left) -> raise_null_safety_error()
      nil -> raise_null_safety_error()
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_having_streaming?({:in, lhs, values}, group_state, scope, params)
       when is_list(values) do
    left = finalize_side(lhs, group_state, scope, params)
    left in Enum.map(values, &finalize_side(&1, group_state, scope, params))
  end

  defp eval_having_streaming?({:in, lhs, list_expr}, group_state, scope, params) do
    left = finalize_side(lhs, group_state, scope, params)

    case finalize_side(list_expr, group_state, scope, params) do
      list when is_list(list) -> left in list
      other -> raise ArgumentError, "in ... expects a list value, got: #{inspect(other)}"
    end
  end

  defp eval_having_streaming?({:and, l, r}, group_state, scope, params),
    do:
      eval_having_streaming?(l, group_state, scope, params) and
        eval_having_streaming?(r, group_state, scope, params)

  defp eval_having_streaming?({:or, l, r}, group_state, scope, params),
    do:
      eval_having_streaming?(l, group_state, scope, params) or
        eval_having_streaming?(r, group_state, scope, params)

  defp eval_having_streaming?({:not, p}, group_state, scope, params),
    do: not eval_having_streaming?(p, group_state, scope, params)

  defp finalize_side(path, %{representative: rep}, scope, _params) when is_list(path),
    do: get_path(rep, scope, path)

  defp finalize_side({:literal, value}, _group_state, _scope, _params), do: value

  defp finalize_side({:call, name, args}, group_state, _scope, _params)
       when name in @streaming_capable_aggregate_names,
       do: finalize_agg(Map.fetch!(group_state.aggs, {name, args}), name)

  defp finalize_side(expr, %{representative: rep}, scope, params),
    do: resolve_rhs(expr, rep, scope, params)

  defp finalize_grouped_row(query, group_state, scope, params),
    do: Map.new(query.select, &finalize_body_item(&1, group_state, scope, params))

  defp finalize_body_item({:field, path}, %{representative: rep}, scope, _params),
    do: {List.last(path), get_path(rep, scope, path)}

  defp finalize_body_item({:computed, alias_name, expr}, group_state, scope, params),
    do: {alias_name, finalize_expr(expr, group_state, scope, params)}

  defp finalize_expr({:call, name, args}, group_state, _scope, _params)
       when name in @streaming_capable_aggregate_names,
       do: finalize_agg(Map.fetch!(group_state.aggs, {name, args}), name)

  defp finalize_expr(expr, %{representative: rep}, scope, params),
    do: resolve_rhs(expr, rep, scope, params)

  # `:empty` (a group with zero contributing rows) can't actually occur
  # -- a group only ever exists because at least one row created it
  # (`new_group/3`) -- but matches `apply_aggregate/2`'s own defined
  # "empty" answer defensively rather than leaving it a `FunctionClause
  # Error` waiting to happen if that invariant is ever weakened later.
  defp finalize_agg(:empty, _name), do: nil
  defp finalize_agg(value, name) when name in ["sum", "min", "max"], do: value
  defp finalize_agg(count, "count") when is_integer(count), do: count
  defp finalize_agg(%MapSet{} = set, "count"), do: MapSet.size(set)
  defp finalize_agg({:empty, _count}, "avg"), do: nil
  defp finalize_agg({sum, count}, "avg"), do: Rational.div(sum, count)

  # `GROUP BY`/aggregate-function path (lang_spec.md §5.2/§5.8, "Groups
  # filtered rows" / the fixed built-in-function set). No explicit
  # `GROUP BY` is not a special case -- `group_rows/3` returns a single
  # implicit group containing every filtered row when `query.group_bys`
  # is empty, which is exactly what makes a *flat* aggregate (lang_spec
  # §11's own nested, un-grouped `SELECT orders { count(id), sum(total)
  # }`) work: it collapses to one output row, the same way `GROUP BY`
  # collapses each distinct key's own rows to one.
  #
  # Sorts *after* projection, unlike `run_plain/6` -- `order_by`'s own
  # "reference a field outside the projected shape" allowance
  # (`sort_rows/3`'s own comment) only makes sense pre-projection, but a
  # grouped/aggregate row has no such outside-the-shape *source* row left
  # once grouping has collapsed multiple rows into one; only the
  # already-computed group/aggregate values exist to sort by. Empty
  # `scope` here is deliberate, not a placeholder -- `sort_rows`/
  # `sorts_before?`/`get_path` are reused completely unchanged, and an
  # empty scope makes the qualified-lookup branch inside `get_path/3` a
  # strict no-op (same guarantee a top-level, non-nested `run/3` call
  # already relies on), which is exactly right: a projected/grouped row
  # has no ancestor scope chain of its own to speak of.
  defp run_grouped(query, filtered, own_name, scope, params, engine_module, conn) do
    with {:ok, projected} <-
           grouped_base_rows(query, filtered, own_name, scope, params, engine_module, conn) do
      {:ok,
       projected
       |> sort_rows(query.order_bys, [])
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  # The HAVING-filtered, projected group rows -- one map per group,
  # keyed by each `select` item's own alias -- *before* `ORDER BY`/
  # `DISTINCT`/`LIMIT`+`OFFSET` are applied. Factored out of `run_
  # grouped/6` above so `run_grouped_with_windows/6` (below) can reuse
  # the exact same grouping/`HAVING`/projection logic and apply window
  # functions to these rows *before* that trailing sort/dedupe/paginate
  # step runs -- a window function's own `PARTITION BY`/`ORDER BY`/frame
  # need the *whole*, unpaginated group-row set to make sense of, the
  # same reason `run_plain/8` computes window values against `filtered`
  # rather than the final `sorted`/paginated rows.
  defp grouped_base_rows(query, filtered, own_name, scope, params, engine_module, conn) do
    grouped =
      query.group_bys
      |> group_levels(query.group_mode)
      |> Enum.flat_map(fn active_fields ->
        filtered
        |> group_rows(active_fields, scope)
        |> Enum.map(&{active_fields, &1})
      end)

    project_groups(query, grouped, own_name, scope, params, engine_module, conn)
  end

  # `select`'s own window-containing items (lang_spec.md §5.5/§5.8)
  # combined with a real `GROUP BY`/aggregate query in the same
  # `select` -- real SQL applies a window function *after* `GROUP BY`/
  # `HAVING` collapse the source rows into one row per group, over
  # that already-grouped/aggregated result set, not the original
  # per-source rows; this mirrors that. `query.group_mode == :plain`
  # is guaranteed by `run/6`'s own dispatch above (`ROLLUP`/`CUBE`
  # combined with a window function still raises there, unchanged) --
  # multiple simultaneous per-level grouping *and* per-level window
  # computation is real, additional complexity deliberately left out
  # of this increment's own scope.
  #
  # `collect_and_rewrite_window_calls/1` walks every `select` item, not
  # just the ones containing a window -- a plain `{:field, path}` item,
  # or a `{:computed, alias, expr}` item with no window anywhere inside
  # `expr`, comes back byte-identical to how it went in (confirmed by
  # construction: `rewrite_body_item/2`'s own fallback clause returns
  # its argument unchanged, and every recursive `rewrite_expr/2` clause
  # reconstructs an equal term when nothing inside actually changed).
  # That structural equality is exactly how `plain_select`/`window_
  # select` below are told apart -- no separate "does this item contain
  # a window" walk duplicated here.
  #
  # `plain_select` drives an ordinary `GROUP BY`/aggregate pass (reusing
  # `grouped_base_rows/7`/`grouped_base_rows_streaming/7` verbatim,
  # streaming when `streaming_aggregate_plan/1` allows it, exactly the
  # same choice `run/6` already makes for a windowless aggregate query)
  # to produce one output row per group, keyed by each plain item's own
  # alias -- a window's own aggregate-as-window call (`sum(total) OVER
  # (...)`, say) is never part of this pass, so it can never accidentally
  # feed a `HAVING`/grouping decision meant only for real, per-group
  # aggregates. `augment_with_window_values/4` then treats those base
  # rows exactly the way `run_plain/8` already treats raw filtered rows
  # -- an ordinary list of flat maps to partition/sort/frame -- so a
  # window's own `PARTITION BY`/`ORDER BY`/aggregate-as-window `args`
  # correctly resolve against the *group's own output columns* (real SQL
  # semantics: you can `PARTITION BY`/`ORDER BY` a `GROUP BY` key or a
  # `SELECT`-list alias, not an original per-source-row field that no
  # longer exists once grouping has collapsed multiple rows into one).
  defp run_grouped_with_windows(
         query,
         own_name,
         scope,
         params,
         with_bindings,
         engine_module,
         conn
       ) do
    {windows, rewritten_select} = collect_and_rewrite_window_calls(query.select)

    {plain_select, window_select} =
      query.select
      |> Enum.zip(rewritten_select)
      |> Enum.split_with(fn {original, rewritten} -> original == rewritten end)

    plain_select = Enum.map(plain_select, &elem(&1, 1))
    window_select = Enum.map(window_select, &elem(&1, 1))
    base_query = %{query | select: plain_select}

    base_result =
      case streaming_aggregate_plan(base_query) do
        {:ok, plan} ->
          grouped_base_rows_streaming(
            base_query,
            plan,
            scope,
            params,
            with_bindings,
            engine_module,
            conn
          )

        :not_streamable ->
          with {:ok, filtered} <-
                 fetch_and_filter(query, scope, params, with_bindings, engine_module, conn) do
            grouped_base_rows(base_query, filtered, own_name, scope, params, engine_module, conn)
          end
      end

    with {:ok, base_rows} <- base_result do
      final_rows =
        base_rows
        |> augment_with_window_values(windows, [], params)
        |> Enum.map(&finalize_windowed_row(&1, window_select, windows, params))

      {:ok,
       final_rows
       |> sort_rows(query.order_bys, [])
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  # Resolves each window item's own (rewritten) expr against `row`
  # (already carrying every plain item's own value, under its real
  # alias, *plus* each window's own precomputed value under its
  # synthetic key -- `augment_with_window_values/4`'s own contract),
  # then drops the synthetic keys before returning -- the same "rewrite
  # the AST, augment the rows, project, then the synthetic keys were
  # only ever an implementation detail" posture `run_plain/8` already
  # has, just with the projection step split from the augmentation step
  # here since the plain items were already projected by `grouped_base_
  # rows/7`/`grouped_base_rows_streaming/7` before augmentation ever ran.
  defp finalize_windowed_row(row, window_select, windows, params) do
    with_window_values =
      Enum.reduce(window_select, row, fn {:computed, alias_name, expr}, acc ->
        Map.put(acc, alias_name, resolve_rhs(expr, acc, [], params))
      end)

    Map.drop(with_window_values, Enum.map(0..(length(windows) - 1)//1, &window_key/1))
  end

  # The list of *grouping levels* `query.group_mode` needs -- each an
  # `active_fields` subset of `group_bys` naming exactly which columns
  # are actually grouped-by at that level (the rest project as `nil`,
  # `project_group_item/7`'s own `{:field, path}` clause). `:plain` is
  # the trivial single-level case (unchanged from before ROLLUP/CUBE
  # existed, confirmed by construction: `[group_bys]` is exactly what
  # `run_grouped/6` always passed to `group_rows/3` before this
  # existed). `:rollup`'s own *n+1* levels are the standard SQL
  # right-to-left prefix hierarchy (`[a,b,c]`, `[a,b]`, `[a]`, `[]` for
  # 3 columns) -- detail first, grand total last. `:cube`'s own *2^n*
  # levels are the full powerset (every subset, not just prefixes),
  # sorted by descending size so detail still precedes every coarser
  # subtotal -- same "finest first, grand total last" convention as
  # `:rollup`, generalized; same-size subsets have no further
  # meaningful order of their own, so `Enum.sort_by/2`'s own stability
  # just keeps `powerset/1`'s own generation order for those, a real
  # but deliberately unremarkable tie-break.
  @spec group_levels([[String.t()]], :plain | :rollup | :cube) :: [[[String.t()]]]
  defp group_levels(group_bys, :plain), do: [group_bys]

  defp group_levels(group_bys, :rollup) do
    n = length(group_bys)
    Enum.map(0..n, fn k -> Enum.take(group_bys, n - k) end)
  end

  defp group_levels(group_bys, :cube) do
    group_bys |> powerset() |> Enum.sort_by(&(-length(&1)))
  end

  defp powerset([]), do: [[]]

  defp powerset([head | tail]) do
    rest = powerset(tail)
    rest ++ Enum.map(rest, &[head | &1])
  end

  # Manual order-preserving partition, not `Enum.group_by/2` -- that
  # function's own map-based grouping gives no guarantee about the order
  # groups (or a group's own members) come back in, and this module's
  # existing determinism discipline (`sort_rows/3`'s own stability
  # comment) already treats "well-defined even when not required" as
  # worth the extra few lines. `group_bys == []` returns a single
  # implicit group with every filtered row -- see `run_grouped/7`'s own
  # comment for why that's the mechanism a flat aggregate needs, not a
  # separate code path.
  defp group_rows(rows, [], _scope), do: [rows]

  defp group_rows(rows, group_bys, scope) do
    {order, groups} =
      Enum.reduce(rows, {[], %{}}, fn row, {order, groups} ->
        key = Enum.map(group_bys, &get_path(row, scope, &1))

        case Map.has_key?(groups, key) do
          true -> {order, Map.update!(groups, key, &[row | &1])}
          false -> {[key | order], Map.put(groups, key, [row])}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse(Map.fetch!(groups, &1)))
  end

  # lang_spec.md §5.8's real aggregates -- the only names that ever
  # trigger grouped execution below. A *cast* (`string`/`int`/`exact`/
  # `inexact`) is a real, non-aggregate function call and must NOT
  # trigger it: an ordinary per-row `SELECT products { p: string(price)
  # }` needs to stay on the per-row path (`run_plain/6`) and produce one
  # row per product, not collapse into a single flat-aggregate-shaped
  # row the way this detection used to treat *any* call as a signal for
  # (a real, since-fixed bug -- found while adding casts, not present
  # before them, since no non-aggregate call existed to expose it).
  @aggregate_names [
    "sum",
    "avg",
    "count",
    "min",
    "max",
    "stddev_samp",
    "stddev_pop",
    "var_samp",
    "var_pop",
    "percentile"
  ]

  # lang_spec.md §5.8's 4 explicit casts, plus `json` (§5.8/§7's own
  # "String reinterpreted as JSON" escape hatch -- the same per-value
  # dispatch shape as a cast, even though lang_spec's own table lists it
  # separately from the 4 "Explicit casts" proper) -- valid per-row
  # (unlike `@aggregate_names`, which only ever mean something across a
  # group's own member rows), dispatched via `apply_cast/2`.
  @cast_names ["string", "int", "exact", "inexact", "json"]

  # A query needs grouped execution when it either has a real `GROUP BY`,
  # or calls one of `@aggregate_names` anywhere in its own `select`/
  # `havings`. A call to anything else (a cast, or a genuinely unknown
  # name) does *not* trigger this -- `resolve_rhs/4`/`resolve_predicate_
  # lhs/3` below handle those directly on the per-row path now, with
  # their own clear errors for an unknown name.
  defp aggregate_query?(query),
    do:
      query.group_bys != [] or select_has_aggregate_call?(query.select) or
        havings_have_aggregate_call?(query.havings)

  defp select_has_aggregate_call?(items), do: Enum.any?(items, &body_item_has_aggregate_call?/1)

  defp body_item_has_aggregate_call?({:computed, _alias, expr}),
    do: expr_has_aggregate_call?(expr)

  defp body_item_has_aggregate_call?(_other), do: false

  defp havings_have_aggregate_call?(havings),
    do: Enum.any?(havings, &predicate_has_aggregate_call?/1)

  defp predicate_has_aggregate_call?({:cmp, _op, lhs, rhs}),
    do: lhs_has_aggregate_call?(lhs) or expr_has_aggregate_call?(rhs)

  # `values` is either a real Elixir list (a literal `[...]`, each
  # element checked individually) or a single tagged expr() expected to
  # resolve to the whole list (`Query`'s own `{:in, lhs, values}`
  # moduledoc paragraph) -- `is_list/1` tells the two apart the same way
  # `Scry.Core.Actions.wrap_field_path/1` and `eval_predicate/4`'s own
  # `{:in, ...}` clause below both do.
  defp predicate_has_aggregate_call?({:in, lhs, values}) when is_list(values),
    do: lhs_has_aggregate_call?(lhs) or Enum.any?(values, &expr_has_aggregate_call?/1)

  defp predicate_has_aggregate_call?({:in, lhs, list_expr}),
    do: lhs_has_aggregate_call?(lhs) or expr_has_aggregate_call?(list_expr)

  defp predicate_has_aggregate_call?({:and, l, r}),
    do: predicate_has_aggregate_call?(l) or predicate_has_aggregate_call?(r)

  defp predicate_has_aggregate_call?({:or, l, r}),
    do: predicate_has_aggregate_call?(l) or predicate_has_aggregate_call?(r)

  defp predicate_has_aggregate_call?({:not, p}), do: predicate_has_aggregate_call?(p)

  # Recurses into `args` too, not just the call's own outer `name` -- a
  # *cast* wrapping an aggregate (`string(sum(price))`) needs the same
  # "route to grouped/flat-aggregate execution" trigger a bare `sum(
  # price)` already gets, since `sum`'s own args still only mean
  # anything across a group's member rows either way. Found as a real,
  # pre-existing gap (not present before casts existed to nest an
  # aggregate inside) while implementing `count(distinct ...)` --
  # confirmed empirically before fixing: `SELECT products { total:
  # string(sum(price)) }`, no explicit `GROUP BY`, used to raise "not an
  # ordinary per-row expression" instead of correctly collapsing to one
  # flat-aggregate row.
  defp lhs_has_aggregate_call?({:call, name, args}),
    do: name in @aggregate_names or Enum.any?(args, &expr_has_aggregate_call?/1)

  # `json(<field>).path...` can be a predicate's own lhs directly
  # (`predicate_lhs := call_with_path | call | path`) -- same recursion
  # `expr_has_aggregate_call?`'s own `{:dot, ...}` clause below has.
  defp lhs_has_aggregate_call?({:dot, base, _path}), do: expr_has_aggregate_call?(base)

  defp lhs_has_aggregate_call?(path) when is_list(path), do: false

  # `in`'s own literal-on-the-left shape -- a literal value never
  # contains a call.
  defp lhs_has_aggregate_call?({:literal, _value}), do: false

  defp expr_has_aggregate_call?({:call, name, args}),
    do: name in @aggregate_names or Enum.any?(args, &expr_has_aggregate_call?/1)

  # `{:distinct, expr}` (lang_spec.md §5.8's `count(distinct ...)`) is
  # itself always an element of some call's own `args` (`priv/
  # grammar.aether`'s own `call_arg`) -- the clause above's own
  # `Enum.any?(args, &expr_has_aggregate_call?/1)` already reaches this,
  # recursing one level further into the wrapped expression itself.
  defp expr_has_aggregate_call?({:distinct, expr}), do: expr_has_aggregate_call?(expr)

  # `json(<field>).path...` -- `base` (in practice always `{:call,
  # "json", [...]}`, but this recurses generically the same way every
  # other wrapper here does) needs the same detection any other nested
  # call gets, so e.g. `string(sum(x)).foo`-shaped nesting (however
  # nonsensical semantically) still routes to grouped execution instead
  # of hitting a confusing per-row rejection.
  defp expr_has_aggregate_call?({:dot, base, _path}), do: expr_has_aggregate_call?(base)

  defp expr_has_aggregate_call?({:arith, _op, l, r}),
    do: expr_has_aggregate_call?(l) or expr_has_aggregate_call?(r)

  defp expr_has_aggregate_call?({:when, clauses, else_expr}) do
    Enum.any?(clauses, fn {predicate, expr} ->
      predicate_has_aggregate_call?(predicate) or expr_has_aggregate_call?(expr)
    end) or expr_has_aggregate_call?(else_expr)
  end

  # A window-wrapped aggregate (`sum(price) OVER ...`) must *not*
  # trigger `aggregate_query?`'s own `GROUP BY`/flat-aggregate routing
  # -- that inner `sum` is handled entirely by this module's own
  # "Window functions" section below (`compute_window_values/4`), not
  # by `run_grouped/6`. The exact inverse of every other clause in this
  # family: everywhere else, recursing *into* a nested call is the fix
  # (`count(distinct ...)`'s own regression, this module's moduledoc);
  # here, stopping recursion *at* the `{:window, ...}` boundary is the
  # correct behavior, found while designing this feature, not by a
  # regression afterward -- `collect_and_rewrite_window_calls/1` (below)
  # is what actually walks into a window call's own `args`, and it runs
  # long before `aggregate_query?/1` would ever get a chance to.
  defp expr_has_aggregate_call?({:window, _call, _partition_by, _order_bys, _frame}), do: false

  defp expr_has_aggregate_call?(_other), do: false

  # Sorts *source* rows (`get_path/3` against the same row shape `where`
  # filters against), before projection -- not the projected output.
  # lang_spec.md §5.2's own "ordering by a field outside the projected
  # shape ... is a compile-time error" only makes sense read this way:
  # if `order_by` only ever had projected data to sort by, a
  # non-projected field would be *impossible* to reference, not merely
  # illegal -- the error exists specifically because the field is
  # otherwise reachable. `distinct`'s own dedup (`maybe_dedupe/2`) runs
  # *after* this, on the now-sorted projected rows, so the relative
  # order this establishes survives into which duplicate's position
  # "wins" -- `Enum.uniq/1`'s own documented first-occurrence-wins
  # behavior, combined with `Enum.sort/2`'s documented stability
  # (verified empirically, not just cited), makes that deterministic.
  defp sort_rows(rows, [], _scope), do: rows

  defp sort_rows(rows, order_bys, scope),
    do: Enum.sort(rows, &sorts_before?(&1, &2, order_bys, scope))

  defp sorts_before?(_a, _b, [], _scope), do: true

  defp sorts_before?(a, b, [{path, direction} | rest], scope) do
    case term_order(get_path(a, scope, path), get_path(b, scope, path)) do
      :eq -> sorts_before?(a, b, rest, scope)
      :lt -> direction == :asc
      :gt -> direction == :desc
    end
  end

  defp maybe_dedupe(rows, false), do: rows
  defp maybe_dedupe(rows, true), do: Enum.uniq(rows)

  defp paginate(rows, limit, offset) do
    rows
    |> drop_offset(offset)
    |> take_limit(limit)
  end

  defp drop_offset(rows, nil), do: rows
  defp drop_offset(rows, offset), do: Enum.drop(rows, offset)

  defp take_limit(rows, nil), do: rows
  defp take_limit(rows, limit), do: Enum.take(rows, limit)

  defp matches_all?(row, wheres, scope, params),
    do: Enum.all?(wheres, &eval_predicate(&1, row, scope, params))

  # `rhs` is the literal `nil` (`KW_NIL` always produces the bare atom
  # `nil`, unwrapped, `Scry.Core.Actions`' own `:literal` handler --
  # never `{:literal, nil}` or any other tag) -- lang_spec.md §7's own
  # explicit null-check idiom (`WHERE age = nil`, `WHERE NOT (age = nil)
  # AND age > 30`), matched *before* the general clause below so it's
  # always exempt from that clause's own null-safety hard-error, no
  # matter what `left` resolves to.
  defp eval_predicate({:cmp, op, lhs, nil}, row, scope, params),
    do: compare(op, resolve_predicate_lhs(lhs, row, scope, params), nil)

  # `rhs` resolves first (the literal value as-is; another field's value
  # via `{:field, path}`, scope-aware so it can reach across a nesting
  # boundary, lang_spec §5.9; or an external parameter's bound value via
  # `{:param, name}`, lang_spec §5.7/§9), *then* dispatches on what it
  # resolved to. Resolve-then-dispatch (rather than one clause per
  # op/shape combination) closes a real gap the naive split would
  # otherwise reopen: `WHERE name ~ some_field` where `some_field`
  # resolves to a non-regex hits the same (deliberate, documented) crash
  # `Regex.match?/2` itself already gives for a non-string *left*-hand
  # value, not a fresh, undocumented `FunctionClauseError`. No defensive
  # `is_binary/1`/`is_struct/2` guard here either -- the same "not
  # specially hardened against a type mismatch" posture every other
  # predicate in this module already has (e.g. `<`/`>` against
  # mismatched types already "works" via Erlang's own total term order
  # without erroring, just not usefully).
  #
  # `left`/`right` resolving to `nil` here (unlike the literal-`nil`-rhs
  # clause above) is never the explicit null-check idiom -- it's a
  # nullable field genuinely reached unguarded (lang_spec.md §7's own
  # null-safety rule: "comparing a nullable field directly against a
  # typed value is a hard error -- always at runtime"), so it hard-
  # errors the same way `eval_aggregate/5`'s own nil-hard-error already
  # does for an aggregate argument, rather than silently comparing
  # through Erlang's own total term order (`nil` sorting as just another
  # atom, `nil > 30` quietly meaning something no query author intended).
  defp eval_predicate({:cmp, op, lhs, rhs}, row, scope, params) do
    left = resolve_predicate_lhs(lhs, row, scope, params)

    case resolve_rhs(rhs, row, scope, params) do
      _ when is_nil(left) -> raise_null_safety_error()
      nil -> raise_null_safety_error()
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  # Each element resolved the same way a comparison's own right-hand
  # side is -- `in [$a, $b]`/`in [orders.status]` work for exactly the
  # same reason `= $a`/`= orders.status` do, not a separate mechanism.
  defp eval_predicate({:in, lhs, values}, row, scope, params) when is_list(values) do
    resolve_predicate_lhs(lhs, row, scope, params) in Enum.map(
      values,
      &resolve_rhs(&1, row, scope, params)
    )
  end

  # `values` is a single expr() expected to resolve, as a whole, to the
  # list to check membership against (`Query`'s own `{:in, ...}`
  # moduledoc paragraph -- `in metadata.tags`/`in json(metadata).tags`,
  # lang_spec §7's own worked example). Resolved via `resolve_rhs/4`,
  # the same resolver a comparison's own right-hand side already uses --
  # `{:field, ...}`/`{:call, ...}`/`{:dot, ...}` are all resolvable
  # there already, nothing new needed on that side. A clear error, not
  # `Enum.member?/2`'s own opaque `Protocol.UndefinedError`, when the
  # resolved value isn't actually a list (e.g. `in json(metadata).name`
  # where `.name` is a string) -- the same "clear domain error, not a
  # foreign crash" posture `apply_cast/2`'s own error clauses already
  # have.
  defp eval_predicate({:in, lhs, list_expr}, row, scope, params) do
    left = resolve_predicate_lhs(lhs, row, scope, params)

    case resolve_rhs(list_expr, row, scope, params) do
      list when is_list(list) -> left in list
      other -> raise ArgumentError, "in ... expects a list value, got: #{inspect(other)}"
    end
  end

  defp eval_predicate({:and, l, r}, row, scope, params),
    do: eval_predicate(l, row, scope, params) and eval_predicate(r, row, scope, params)

  defp eval_predicate({:or, l, r}, row, scope, params),
    do: eval_predicate(l, row, scope, params) or eval_predicate(r, row, scope, params)

  defp eval_predicate({:not, p}, row, scope, params),
    do: not eval_predicate(p, row, scope, params)

  # `predicate()`'s own lhs is `[String.t()] | {:call, ...}`
  # (`Scry.Core.Query`'s own moduledoc) -- a bare path resolves exactly as
  # it always has. An aggregate call (`@aggregate_names`) is a real,
  # purpose-written error here, not a crash: it only has real execution
  # semantics inside a grouped/aggregate context (`resolve_group_lhs/4`,
  # `run_grouped/7`), which this function -- `matches_all?/4`'s own
  # per-row `WHERE`/`WHEN` predicate evaluation -- never is. Without this
  # clause, `WHEN sum(x) > 1 THEN ...` used per-row would instead hit
  # `get_path/3`'s own missing clause for a 2-tuple path and raise an
  # opaque `FunctionClauseError` with no indication of what actually went
  # wrong. A *cast* (`string`/`int`/`exact`/`inexact`) is a genuinely
  # different case -- it's valid per-row, same as any other expression --
  # so its own args resolve via `resolve_rhs/4` (this row, ordinary
  # correlation/param resolution) and the cast applies to the result.
  defp resolve_predicate_lhs({:call, name, _args}, _row, _scope, _params)
       when name in @aggregate_names do
    raise ArgumentError,
          "#{name}(...) is an aggregate function -- only valid inside GROUP BY/HAVING or a " <>
            "flat-aggregate SELECT (lang_spec.md §5.2/§5.8), not an ordinary per-row predicate"
  end

  defp resolve_predicate_lhs({:call, name, args}, row, scope, params) do
    apply_cast(name, Enum.map(args, &resolve_rhs(&1, row, scope, params)))
  end

  # `json(<field>).path...` (lang_spec §5.8/§7's own `WHERE json(
  # metadata).color = "red"` worked example) -- `base` resolves the same
  # way any other expression on this row does (`resolve_rhs/4`), then
  # `path` walks into the result exactly the way `get_path/3` already
  # walks a path into a row (`get_path_in/2`, the same helper, reused
  # directly -- a decoded JSON value is an ordinary map with string keys,
  # indistinguishable from row data once decoded).
  defp resolve_predicate_lhs({:dot, base, path}, row, scope, params) do
    get_path_in(resolve_rhs(base, row, scope, params), path)
  end

  defp resolve_predicate_lhs(path, row, scope, _params) when is_list(path),
    do: get_path(row, scope, path)

  # `in`'s own literal-on-the-left shape (`Query`'s own `{:in, lhs, ...}`
  # moduledoc paragraph, `"urgent" in metadata.tags`) -- the value is
  # already resolved at parse time, nothing left to look up against the
  # row. Never reached for `:cmp`'s own `lhs` (only `in_lhs`'s own
  # grammar alternative ever produces this tag).
  defp resolve_predicate_lhs({:literal, value}, _row, _scope, _params), do: value

  defp compare(op, a, b), do: ordering_result(op, term_order(a, b))

  # Matches `raise_aggregate_nil_error/1`'s own wording almost verbatim
  # -- lang_spec.md §7's null-safety rule is the ordinary-comparison
  # counterpart of §5.8's aggregate one ("no silent nil-skipping" for
  # either), and shared verbatim by all three `{:cmp, ...}` evaluators
  # this file has (`eval_predicate/4`, `eval_group_predicate/4`,
  # `eval_having_streaming?/4`) so the message -- and the rule itself --
  # stays in parity across all three, not just worded similarly by
  # convention.
  defp raise_null_safety_error do
    raise ArgumentError,
          "comparing a nullable field against a typed value encountered a nil value -- " <>
            "lang_spec.md's own null-safety rule (\"comparing a nullable field directly " <>
            "against a typed value is a hard error\") -- guard it first (e.g. " <>
            "WHERE NOT (field = nil) AND field > ...), or compare against nil explicitly " <>
            "(WHERE field = nil) to check nullness instead"
  end

  # `%Rational{}`/integer/`float()` are compared exactly (cross-
  # multiplication via Rational.compare/2, Scry.Core.Rational's own
  # moduledoc -- a `float()` argument there converts to *its own* exact
  # value first, never the reverse) rather than through Kernel's `< >`,
  # which order structs by their raw field values -- structurally
  # consistent, but not numerically meaningful for two arbitrary
  # rationals (e.g. comparing 1/2 against 2/3 by field order is not the
  # same as comparing their magnitudes). The `is_float(b)` half of this
  # closes a gap this comment used to flag as real-but-unfixed ("a
  # native float there isn't yet covered") -- an `inexact(...)` cast is
  # what actually introduces one now.
  defp term_order(%Rational{} = a, b) when is_integer(b) or is_struct(b, Rational) or is_float(b),
    do: Rational.compare(a, b)

  defp term_order(a, %Rational{} = b) when is_integer(a) or is_float(a),
    do: Rational.compare(a, b)

  # Same problem, a different struct: `%DateTime{}`/`%NaiveDateTime{}`
  # store a microsecond field as a `{value, precision}` tuple, so two
  # values representing the exact same instant at different parsed
  # precision (`14:00:00.5` vs `14:00:00.500000`) are neither `==` nor
  # correctly ordered by Kernel's `< >` -- confirmed empirically
  # (`DateTime.compare/2` says `:eq`, Kernel `<` says `true`, for the
  # same pair) before trusting this needed fixing at all, the same way
  # Rational's own struct-ordering problem was confirmed rather than
  # assumed above. `%Date{}` genuinely doesn't need this -- no
  # microsecond field, so Kernel's own comparison is already exact for
  # it, verified the same way.
  defp term_order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp term_order(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)

  # Erlang's term order is total (number < atom < reference < function <
  # port < pid < tuple < map < list < bitstring, recursively within each
  # kind) -- so `<`/`>` are always well-defined for any two terms, and
  # this genuinely *is* `a == b` whenever neither holds, not an
  # approximation of it. `compare/2`'s own final fallback, and directly
  # used by `sorts_before?/4` for any value type that doesn't need one
  # of the special cases above.
  defp term_order(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  # Shared by `compare/2` above and `sorts_before?/4` -- both ultimately
  # just need to turn a `term_order/2` result into what they
  # respectively want (a boolean for a given comparison operator; a
  # three-way branch for a sort comparator).
  defp ordering_result(:eq, ordering), do: ordering == :eq
  defp ordering_result(:not_eq, ordering), do: ordering != :eq
  defp ordering_result(:lt, ordering), do: ordering == :lt
  defp ordering_result(:gt, ordering), do: ordering == :gt
  defp ordering_result(:le, ordering), do: ordering != :gt
  defp ordering_result(:ge, ordering), do: ordering != :lt

  # A single-segment path is never a qualified (cross-scope) reference --
  # it has nothing after a would-be qualifier to look up -- so it always
  # resolves against the current row directly, the same as with no scope
  # at all. This isn't just a shortcut: without it, a one-segment path
  # whose sole segment happens to match a scope name would fall into the
  # clause below and recurse into `get_path_in(scoped_row, [])`, which
  # has no clause for an empty list.
  #
  # Otherwise, the first segment is checked against `scope` (nearest
  # enclosing query first, per how `scope` is built in `project_item/6`
  # below) -- a match resolves the *rest* of the path against that
  # ancestor's row; no match falls through to ordinary same-row nested
  # lookup (`get_path_in/2`, this module's original, unqualified
  # behavior, entirely unchanged). See this module's own moduledoc for
  # why there is deliberately no equivalent check against the *current*
  # query's own name.
  defp get_path(row, _scope, [_single] = path), do: get_path_in(row, path)

  defp get_path(row, scope, [qualifier | rest] = path) do
    case List.keyfind(scope, qualifier, 0) do
      {^qualifier, scoped_row} -> get_path_in(scoped_row, rest)
      nil -> get_path_in(row, path)
    end
  end

  defp get_path_in(row, [key]), do: Map.get(row, key)
  defp get_path_in(row, [key | rest]), do: row |> Map.get(key, %{}) |> get_path_in(rest)

  defp resolve_rhs({:field, path}, row, scope, _params), do: get_path(row, scope, path)

  # `Map.fetch/2` + an explicit raise, not `Map.fetch!/2` -- gives a
  # clear, scry-specific message (the missing parameter's own name)
  # rather than `KeyError`'s generic "key ... not found in: %{...}",
  # which would also leak the rest of `params` into the error text.
  defp resolve_rhs({:param, name}, _row, _scope, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing external parameter: #{inspect(name)}"
    end
  end

  # Recurses through both operands via this same function -- an
  # arithmetic expression is a tree of `{:field, ...}`/`{:param,
  # ...}`/nested `{:arith, ...}`/plain-literal leaves (`Query.expr/0`),
  # and every one of those shapes is already exactly what `resolve_rhs`
  # handles. Always routed through `Scry.Core.Rational`'s own functions,
  # never Kernel `+ - * /` directly, so a chain of operations stays
  # exact throughout (lang_spec.md §4: "arithmetic never drops to float
  # internally") *unless* an `inexact(...)` cast put a real `float()`
  # somewhere in the tree -- `Rational`'s own contagion rule then
  # applies automatically, from that point on, since every operator
  # routes through the same functions either way (`Scry.Core.Rational`'s
  # own moduledoc).
  defp resolve_rhs({:arith, op, left_expr, right_expr}, row, scope, params) do
    left = resolve_rhs(left_expr, row, scope, params)
    right = resolve_rhs(right_expr, row, scope, params)
    arith(op, left, right)
  end

  # `WHEN <predicate> THEN <expr> [...] ELSE <expr>` (lang_spec.md
  # §5.6/§9) -- walks `clauses` in order via `Enum.find/2`, reusing
  # `eval_predicate/4` directly on each condition (the exact function a
  # `where` clause's own predicates already go through, so a `WHEN` can
  # already do anything `WHERE` can, for free) and resolving the first
  # match's own expression. Falls through to `else_expr` when nothing
  # matches -- always reachable, never `nil`, since the grammar makes
  # `ELSE` mandatory (`priv/grammar.aether`'s own `when_expr`).
  defp resolve_rhs({:when, clauses, else_expr}, row, scope, params) do
    case Enum.find(clauses, fn {predicate, _then_expr} ->
           eval_predicate(predicate, row, scope, params)
         end) do
      {_predicate, then_expr} -> resolve_rhs(then_expr, row, scope, params)
      nil -> resolve_rhs(else_expr, row, scope, params)
    end
  end

  # An aggregate call is a real, purpose-written error here (the same
  # message `resolve_predicate_lhs/4`'s own equivalent clause gives) --
  # `sum`/etc. only mean something across a group's member rows, which
  # this function -- resolving an expression against one already-fetched
  # row -- never has access to. A *cast* resolves its own args against
  # this same row/scope/params (ordinary recursion through this same
  # function) and applies via `apply_cast/2`, the same dispatch
  # `resolve_group_rhs/4` below shares.
  defp resolve_rhs({:call, name, _args}, _row, _scope, _params) when name in @aggregate_names do
    raise ArgumentError,
          "#{name}(...) is an aggregate function -- only valid inside GROUP BY/HAVING or a " <>
            "flat-aggregate SELECT (lang_spec.md §5.2/§5.8), not an ordinary per-row expression"
  end

  defp resolve_rhs({:call, name, args}, row, scope, params) do
    apply_cast(name, Enum.map(args, &resolve_rhs(&1, row, scope, params)))
  end

  # `{:distinct, expr}` (lang_spec.md §5.8: `count(distinct ...)`) can
  # only ever appear as an element of some call's own `args`
  # (`priv/grammar.aether`'s own `call_arg` -- there's no other
  # production reaching this shape) -- `eval_aggregate/5` already
  # intercepts it as `count`'s own single argument before this function
  # ever sees it there. Reaching this clause means it showed up as an
  # arg to something *else* (a cast, e.g. `string(distinct price)`, or a
  # wrong-arity/non-`count` aggregate `resolve_rhs({:call, ...})` above
  # already resolves args for) -- a real, clear error, not silently
  # treating the whole `{:distinct, expr}` tuple as an opaque literal
  # value the way falling through to the catch-all below would.
  defp resolve_rhs({:distinct, _expr}, _row, _scope, _params) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not any other call"
  end

  # `json(<field>).path...` -- same resolution `resolve_predicate_lhs/4`
  # 's own equivalent clause already does (`base` via this same
  # function, `path` walked into the result via `get_path_in/2`).
  defp resolve_rhs({:dot, base, path}, row, scope, params) do
    get_path_in(resolve_rhs(base, row, scope, params), path)
  end

  defp resolve_rhs(literal, _row, _scope, _params), do: literal

  defp arith(:add, a, b), do: Rational.add(a, b)
  defp arith(:sub, a, b), do: Rational.sub(a, b)
  defp arith(:mul, a, b), do: Rational.mul(a, b)
  defp arith(:div, a, b), do: Rational.div(a, b)
  defp arith(:pow, a, b), do: Rational.pow(a, b)

  # ---- GROUP BY / HAVING / aggregate-function evaluation -----------------
  #
  # A group context is just its own `member_rows` -- a plain field
  # resolves against the group's *representative* row (`representative/1`,
  # its first member, or `%{}` for the one genuinely empty group a
  # zero-row flat aggregate produces), and a call aggregates across every
  # member. No separately tracked group-key map: every member row of a
  # well-formed group already carries the identical value for any field
  # that's actually one of the `GROUP BY` fields, so there's nothing a key
  # map would offer that the representative row doesn't already have --
  # the same "not enforced, but well-defined" posture this module's own
  # moduledoc already documents for a non-grouped `order_by`/`distinct`
  # field.
  #
  # `eval_group_predicate/4`/`resolve_group_lhs/4`/`resolve_group_rhs/4`
  # mirror `eval_predicate/4`/`resolve_rhs/4` exactly, one level up
  # (`member_rows` instead of a single `row`) -- kept as a genuinely
  # separate family, not unified via an extra parameter, the same way
  # `resolve_rhs`/`eval_predicate` themselves are already two parallel
  # families rather than one merged dispatcher.
  # Mirrors `eval_predicate/4`'s own literal-`nil`-rhs exemption --
  # lang_spec.md §7's null-check idiom applies just as much to `HAVING`
  # (`HAVING count(x) = nil` doesn't really make sense, but a bare
  # grouped field like `HAVING status = nil` does), matched before the
  # general clause below for the same reason.
  defp eval_group_predicate({:cmp, op, lhs, nil}, member_rows, scope, params),
    do: compare(op, resolve_group_lhs(lhs, member_rows, scope, params), nil)

  defp eval_group_predicate({:cmp, op, lhs, rhs}, member_rows, scope, params) do
    left = resolve_group_lhs(lhs, member_rows, scope, params)

    case resolve_group_rhs(rhs, member_rows, scope, params) do
      _ when is_nil(left) -> raise_null_safety_error()
      nil -> raise_null_safety_error()
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_group_predicate({:in, lhs, values}, member_rows, scope, params)
       when is_list(values) do
    left = resolve_group_lhs(lhs, member_rows, scope, params)
    left in Enum.map(values, &resolve_group_rhs(&1, member_rows, scope, params))
  end

  # Mirrors `eval_predicate/4`'s own single-expr `{:in, ...}` clause,
  # one level up -- `list_expr` resolved the group-aware way.
  defp eval_group_predicate({:in, lhs, list_expr}, member_rows, scope, params) do
    left = resolve_group_lhs(lhs, member_rows, scope, params)

    case resolve_group_rhs(list_expr, member_rows, scope, params) do
      list when is_list(list) -> left in list
      other -> raise ArgumentError, "in ... expects a list value, got: #{inspect(other)}"
    end
  end

  defp eval_group_predicate({:and, l, r}, member_rows, scope, params),
    do:
      eval_group_predicate(l, member_rows, scope, params) and
        eval_group_predicate(r, member_rows, scope, params)

  defp eval_group_predicate({:or, l, r}, member_rows, scope, params),
    do:
      eval_group_predicate(l, member_rows, scope, params) or
        eval_group_predicate(r, member_rows, scope, params)

  defp eval_group_predicate({:not, p}, member_rows, scope, params),
    do: not eval_group_predicate(p, member_rows, scope, params)

  # `name in @aggregate_names` -- a real aggregate reduces across
  # `member_rows` (`eval_aggregate/5`, unchanged); anything else (a
  # cast) resolves its own args the *group*-aware way (recursion through
  # this same function, so a cast wrapping an aggregate or a grouped
  # field both work for free -- `string(sum(total))` resolves `sum
  # (total)` via the aggregate branch, `string(region)` resolves
  # `region` against the representative row, either way ending up as a
  # single already-resolved value `apply_cast/2` then applies to) and
  # applies via the same `apply_cast/2` the per-row path shares.
  defp resolve_group_lhs({:call, name, args}, member_rows, scope, params) do
    if name in @aggregate_names do
      eval_aggregate(name, args, member_rows, scope, params)
    else
      apply_cast(name, Enum.map(args, &resolve_group_rhs(&1, member_rows, scope, params)))
    end
  end

  # `json(<field>).path...` -- `base` resolves the group-aware way
  # (recursion through `resolve_group_rhs/4`, so it composes with an
  # aggregate/grouped field the same way `{:call, ...}`'s own cast
  # branch above already does), `path` walked into the result via
  # `get_path_in/2`, same as every other `{:dot, ...}` resolution site.
  defp resolve_group_lhs({:dot, base, path}, member_rows, scope, params) do
    get_path_in(resolve_group_rhs(base, member_rows, scope, params), path)
  end

  defp resolve_group_lhs(path, member_rows, scope, _params) when is_list(path),
    do: get_path(representative(member_rows), scope, path)

  # Mirrors `resolve_predicate_lhs/4`'s own `{:literal, ...}` clause.
  defp resolve_group_lhs({:literal, value}, _member_rows, _scope, _params), do: value

  defp resolve_group_rhs({:call, name, args}, member_rows, scope, params) do
    if name in @aggregate_names do
      eval_aggregate(name, args, member_rows, scope, params)
    else
      apply_cast(name, Enum.map(args, &resolve_group_rhs(&1, member_rows, scope, params)))
    end
  end

  defp resolve_group_rhs({:field, path}, member_rows, scope, _params),
    do: get_path(representative(member_rows), scope, path)

  defp resolve_group_rhs({:param, name}, _member_rows, _scope, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing external parameter: #{inspect(name)}"
    end
  end

  defp resolve_group_rhs({:arith, op, left_expr, right_expr}, member_rows, scope, params) do
    left = resolve_group_rhs(left_expr, member_rows, scope, params)
    right = resolve_group_rhs(right_expr, member_rows, scope, params)
    arith(op, left, right)
  end

  defp resolve_group_rhs({:when, clauses, else_expr}, member_rows, scope, params) do
    case Enum.find(clauses, fn {predicate, _then_expr} ->
           eval_group_predicate(predicate, member_rows, scope, params)
         end) do
      {_predicate, then_expr} -> resolve_group_rhs(then_expr, member_rows, scope, params)
      nil -> resolve_group_rhs(else_expr, member_rows, scope, params)
    end
  end

  # Same reasoning as `resolve_rhs/4`'s own equivalent clause -- reaching
  # this means `{:distinct, expr}` showed up somewhere other than
  # `count`'s own single argument, which `eval_aggregate/5` already
  # intercepts before this function ever sees it there.
  defp resolve_group_rhs({:distinct, _expr}, _member_rows, _scope, _params) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not any other call"
  end

  # Same resolution `resolve_group_lhs/4`'s own equivalent clause above
  # already does.
  defp resolve_group_rhs({:dot, base, path}, member_rows, scope, params) do
    get_path_in(resolve_group_rhs(base, member_rows, scope, params), path)
  end

  defp resolve_group_rhs(literal, _member_rows, _scope, _params), do: literal

  defp representative([]), do: %{}
  defp representative([row | _rest]), do: row

  # lang_spec.md line 399: "Aggregates over nullable fields hard-error the
  # same way [as comparing a nullable field directly] -- no silent
  # nil-skipping; filter explicitly first." All 5 real aggregates raise,
  # uniformly, the moment *any* resolved operand value is `nil` -- no
  # special-cased "COUNT skips nulls" carve-out the way SQL's own
  # COUNT(column) has, since the spec line doesn't give aggregates one.
  # Unknown function name and wrong argument count raise the same way,
  # for the same reason `resolve_rhs/4`'s own missing-external-param and
  # non-regex `~`-match cases already raise rather than returning
  # `{:error, _}` -- a caller-fixable, runtime-discovered problem, not a
  # data-shaped one this module's `{:error, _}`-threading pipeline
  # (`project`/`project_all`) is built around.
  # `name in @aggregate_names` is guaranteed by every call site
  # (`resolve_group_lhs/4`/`resolve_group_rhs/4` above only ever call
  # this once they've already checked) -- no catch-all "unknown
  # function" clause here the way an earlier version of this function
  # had one; a genuinely unknown name is `apply_cast/2`'s own concern
  # now, not reachable here at all, so there's nothing left to validate
  # defensively against.
  # `count(distinct ...)` (lang_spec.md §5.8) -- deduped *after* the same
  # nil hard-error every other aggregate already gets (no carve-out;
  # `Enum.uniq/1` itself would happily let a single `nil` through
  # otherwise, silently treating "no value" as one more distinct value
  # to count, which the spec's own "no silent nil-skipping" line already
  # forbids for aggregates generally). Declared *before* the generic
  # `[arg]` clause below -- `[{:distinct, arg}]` would otherwise also
  # structurally match `[arg]` (a single-element list is a single-element
  # list), silently treating the whole `{:distinct, ...}` tuple as
  # `sum`/`avg`/etc.'s own literal argument value instead of dispatching
  # here.
  defp eval_aggregate("count", [{:distinct, arg}], member_rows, scope, params) do
    values = Enum.map(member_rows, &resolve_rhs(arg, &1, scope, params))

    if Enum.any?(values, &is_nil/1) do
      raise ArgumentError,
            "aggregate count(distinct ...) encountered a nil value -- lang_spec.md's own " <>
              "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
              "nil-skipping); filter it out explicitly first"
    end

    values |> Enum.uniq() |> length()
  end

  # `distinct` only means anything for `count` (lang_spec.md §5.8 lists
  # it nowhere else) -- `sum(distinct x)`/`avg(distinct x)`/etc. are
  # syntactically reachable (`priv/grammar.aether`'s own `call_arg`
  # comment: the grammar stays permissive, execution rejects misuse) but
  # a real, clear error here, not silently treated as `sum`'s own literal
  # argument.
  defp eval_aggregate(name, [{:distinct, _arg}], _member_rows, _scope, _params) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not #{name}(...)"
  end

  # `percentile(expr, p)` (lang_spec.md §5.8: "General ordered-set
  # aggregate, p ∈ [0,1]; median = percentile(x, 0.5)") -- the one
  # standard aggregate that isn't single-argument, so it needs its own
  # clauses, declared *before* the generic `[arg]`/catch-all clauses
  # below -- otherwise a wrong-arity `percentile(x)` call (a genuine
  # one-element `args` list) would match the generic `[arg]` clause
  # instead of raising a `percentile`-specific arity error, and later
  # crash inside `apply_aggregate/2` with an opaque `FunctionClauseError`
  # (confirmed empirically before fixing the ordering, not assumed).
  # `p` is a single scalar, not one value per member row -- resolved
  # once against the group's own representative row (`representative/1`,
  # the same row a plain field on a predicate's own group-lhs already
  # resolves against), not mapped across `member_rows` the way
  # `value_arg` is. `p`'s own out-of-range check runs before scanning
  # `value_arg` at all -- an obviously-wrong `p` should fail fast, not
  # after walking every member row for no reason.
  defp eval_aggregate("percentile", [value_arg, p_arg], member_rows, scope, params) do
    p = resolve_rhs(p_arg, representative(member_rows), scope, params)

    unless compare(:ge, p, 0) and compare(:le, p, 1) do
      raise ArgumentError,
            "percentile(...)'s own p must be between 0 and 1, got: #{inspect(p)}"
    end

    values = Enum.map(member_rows, &resolve_rhs(value_arg, &1, scope, params))

    if Enum.any?(values, &is_nil/1) do
      raise ArgumentError,
            "aggregate percentile(...) encountered a nil value -- lang_spec.md's own " <>
              "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
              "nil-skipping); filter it out explicitly first"
    end

    apply_percentile(values, p)
  end

  defp eval_aggregate("percentile", args, _member_rows, _scope, _params) do
    raise ArgumentError,
          "aggregate percentile/2 expects exactly two arguments (value, p), got #{length(args)}"
  end

  defp eval_aggregate(name, [arg], member_rows, scope, params) do
    values = Enum.map(member_rows, &resolve_rhs(arg, &1, scope, params))

    if Enum.any?(values, &is_nil/1) do
      raise ArgumentError,
            "aggregate #{name}(...) encountered a nil value -- lang_spec.md's own " <>
              "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
              "nil-skipping); filter it out explicitly first"
    end

    apply_aggregate(name, values)
  end

  defp eval_aggregate(name, args, _member_rows, _scope, _params) do
    raise ArgumentError, "aggregate #{name}/1 expects exactly one argument, got #{length(args)}"
  end

  # Empty-group results match real SQL, not one blanket default:
  # `count([])` is `0` (an empty group still has a defined count) while
  # `sum`/`avg`/`min`/`max` of `[]` are `nil` (no defined sum/average/
  # extremum over zero values) -- this is what makes a flat aggregate
  # over zero *filtered* rows still produce exactly one well-defined
  # output row (`count(id) = 0` is the correct answer for "this user has
  # no orders," not a dropped row or a crash).
  defp apply_aggregate("count", values), do: length(values)
  defp apply_aggregate("sum", []), do: nil
  defp apply_aggregate("sum", values), do: Enum.reduce(values, &Rational.add/2)
  defp apply_aggregate("avg", []), do: nil

  defp apply_aggregate("avg", values),
    do: Rational.div(Enum.reduce(values, &Rational.add/2), length(values))

  defp apply_aggregate("min", []), do: nil
  defp apply_aggregate("min", values), do: Enum.reduce(values, &pick_min/2)
  defp apply_aggregate("max", []), do: nil
  defp apply_aggregate("max", values), do: Enum.reduce(values, &pick_max/2)

  # `var_pop`/`var_samp`/`stddev_pop`/`stddev_samp` (lang_spec.md §5.8,
  # "ANSI SQL:2003 forms -- no ambiguous unqualified `stddev`"). Mean and
  # sum-of-squared-deviations stay in the exact-rational tower throughout
  # (`variance/2` below, via `Rational.add/sub/mul/div`) -- only the
  # final `stddev_*` step needs a real square root, which the rationals
  # aren't closed under (this module's own moduledoc, and `Rational`'s
  # own "sqrt's per-input exactness recovery isn't here" note), so it
  # goes through `Rational.to_float/1` + `:math.sqrt/1` and the result is
  # a plain `float()` -- the one place these 4 aggregates are ever
  # inexact. `_samp` (Bessel's correction, dividing by `n - 1`) is
  # undefined below 2 data points, mirroring the SQL-standard "`NULL` for
  # too little data" answer `_pop`'s own `[]` case (line above) already
  # gives for zero -- both real, defined "no data" answers, not a
  # dropped row or a crash.
  defp apply_aggregate("var_pop", []), do: nil
  defp apply_aggregate("var_pop", values), do: variance(values, length(values))
  defp apply_aggregate("var_samp", values) when length(values) < 2, do: nil
  defp apply_aggregate("var_samp", values), do: variance(values, length(values) - 1)
  defp apply_aggregate("stddev_pop", []), do: nil
  defp apply_aggregate("stddev_pop", values), do: values |> variance(length(values)) |> sqrt()
  defp apply_aggregate("stddev_samp", values) when length(values) < 2, do: nil

  defp apply_aggregate("stddev_samp", values),
    do: values |> variance(length(values) - 1) |> sqrt()

  defp variance(values, divisor) do
    mean = Rational.div(Enum.reduce(values, &Rational.add/2), length(values))

    sum_sq =
      Enum.reduce(values, 0, fn x, acc ->
        deviation = Rational.sub(x, mean)
        Rational.add(acc, Rational.mul(deviation, deviation))
      end)

    Rational.div(sum_sq, divisor)
  end

  defp sqrt(x), do: x |> Rational.to_float() |> :math.sqrt()

  # `percentile(expr, p)` -- discrete order-statistic (nearest-rank
  # method: sort ascending via `term_order/2`, the same struct-aware
  # ordering `min`/`max` above already use, then pick the value at rank
  # `ceil(p * n)`, clamped to `[1, n]`), not the continuous/interpolated
  # variant SQL calls `percentile_cont`. Deliberate: lang_spec's own
  # "General ordered-set aggregate" framing (not "numeric aggregate")
  # implies it works over *any* orderable value `term_order/2` already
  # handles -- dates, strings, mixed exact/inexact numbers -- and
  # interpolating between two neighboring values only ever makes sense
  # for numbers; nearest-rank always picks an actual value from the set,
  # so it's well-defined uniformly. `p = 0` picks the minimum, `p = 1`
  # the maximum, `p = 0.5` the (lower, for an even `n`) median --
  # matching `median = percentile(x, 0.5)`'s own worked example closely
  # enough without claiming SQL's exact averaging behavior for it.
  defp apply_percentile(values, p) do
    sorted = Enum.sort(values, &(term_order(&1, &2) != :gt))
    n = length(sorted)
    rank = p |> Rational.mul(n) |> ceil_toward_pos_infinity() |> max(1) |> min(n)
    Enum.at(sorted, rank - 1)
  end

  defp ceil_toward_pos_infinity(x) when is_float(x), do: ceil(x)
  defp ceil_toward_pos_infinity(x) when is_integer(x), do: x

  defp ceil_toward_pos_infinity(%Rational{numerator: n, denominator: d}),
    do: Kernel.div(n, d) + if(Kernel.rem(n, d) == 0, do: 0, else: 1)

  # Via `term_order/2`, not Kernel `min`/`max` -- the exact same
  # `Rational`/`DateTime`/`NaiveDateTime` struct-ordering correctness
  # `term_order/2` already exists for (its own comment has the full
  # reasoning); Kernel's `min`/`max` would order two `%Rational{}`s by
  # raw field values, not by magnitude, same bug class `compare/2`
  # already avoids for ordinary comparisons.
  defp pick_min(a, b), do: if(term_order(a, b) == :lt, do: a, else: b)
  defp pick_max(a, b), do: if(term_order(a, b) == :gt, do: a, else: b)

  # lang_spec.md §5.8's other 4 built-in functions -- "Explicit casts --
  # always explicit, never implicit." Reached from `resolve_rhs/4`,
  # `resolve_predicate_lhs/4`, `resolve_group_lhs/4`, and
  # `resolve_group_rhs/4` alike, always with `args` already resolved via
  # *that call site's own* resolver -- a cast never resolves its own
  # arguments itself, so `string(sum(total))`/`string(region)` both just
  # work, the exact same recursive composition `{:arith, ...}`/`{:when,
  # ...}` already get for free elsewhere in this module.
  defp apply_cast("string", [value]), do: cast_to_string(value)
  defp apply_cast("int", [value]), do: cast_to_int(value)
  defp apply_cast("exact", [value]), do: cast_to_exact(value)
  defp apply_cast("inexact", [value]), do: Rational.to_float(value)
  defp apply_cast("json", [value]), do: cast_to_json(value)

  defp apply_cast(name, args) when name in @cast_names do
    raise ArgumentError, "cast #{name}/1 expects exactly one argument, got #{length(args)}"
  end

  defp apply_cast(name, _args) do
    raise ArgumentError, "unknown or unsupported function: #{inspect(name)}"
  end

  # Scry's own concrete value universe (`Scry.Core.Actions`' own
  # `handle_token` clauses are the exhaustive list of what a literal can
  # ever produce; a row field can be any of these plus whatever an
  # engine's own `fetch/2` returns, assumed to already be one of them) --
  # not arbitrary Elixir terms. A value outside it raises a clear error
  # rather than silently falling back to `inspect/1`-shaped text nobody
  # asked for. `%Rational{}` renders as `numerator/denominator` -- the
  # same shape it'd be *written* as a literal, not a lossy decimal
  # (`1/3` has no terminating decimal at all) -- and `Date`/`DateTime`/
  # `NaiveDateTime` round-trip through the exact ISO 8601 shape
  # `Scry.Core.Actions`' own `handle_token(:DATE, ...)` parsed them from.
  defp cast_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp cast_to_string(%Rational{numerator: n, denominator: d}), do: "#{n}/#{d}"
  defp cast_to_string(f) when is_float(f), do: Float.to_string(f)
  defp cast_to_string(s) when is_binary(s), do: s
  defp cast_to_string(true), do: "true"
  defp cast_to_string(false), do: "false"
  defp cast_to_string(nil), do: "nil"
  defp cast_to_string(%Date{} = d), do: Date.to_iso8601(d)
  defp cast_to_string(%DateTime{} = d), do: DateTime.to_iso8601(d)
  defp cast_to_string(%NaiveDateTime{} = d), do: NaiveDateTime.to_iso8601(d)
  defp cast_to_string({:atom, name}), do: name

  defp cast_to_string(other) do
    raise ArgumentError, "string(...) does not support this value: #{inspect(other)}"
  end

  # Truncates toward zero (the ordinary "int cast" convention, not
  # `floor`) -- exact integer division on a `%Rational{}`'s own parts
  # (`Kernel.div/2`, which already truncates toward zero for a negative
  # dividend, not just a positive one), never a lossy `trunc/1` on a
  # computed float, so this stays correct for arbitrarily large
  # numerators/denominators.
  defp cast_to_int(n) when is_integer(n), do: n
  defp cast_to_int(%Rational{numerator: n, denominator: d}), do: Kernel.div(n, d)
  defp cast_to_int(f) when is_float(f), do: trunc(f)

  defp cast_to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> raise ArgumentError, "int(...) could not parse #{inspect(s)} as an integer"
    end
  end

  defp cast_to_int(other) do
    raise ArgumentError, "int(...) does not support this value: #{inspect(other)}"
  end

  # `exact(...)` is idempotent over anything already exact (lang_spec.md
  # §4's own numeric tower has no separate "int" vs "rational" exact
  # type to convert *between* -- `new/2` already collapses a whole
  # denominator to a plain integer); only a real `float()` has anything
  # to actually convert (`Rational.from_float/1`).
  defp cast_to_exact(n) when is_integer(n), do: n
  defp cast_to_exact(%Rational{} = r), do: r
  defp cast_to_exact(f) when is_float(f), do: Rational.from_float(f)

  defp cast_to_exact(other) do
    raise ArgumentError, "exact(...) does not support this value: #{inspect(other)}"
  end

  # `json(<field>)` (lang_spec.md §5.8/§7: "Reinterprets a String as
  # JSON for one qualified dot-path access, no schema change") --
  # `:json` is Erlang/OTP's own stdlib module (added in OTP 27; this
  # project already targets OTP 28, confirmed via `.tool-versions`), not
  # a new dependency. Decodes into an ordinary map with *string* keys
  # directly (confirmed empirically, not assumed), the exact shape
  # `get_path_in/2` already expects -- once decoded, a `json(...)`
  # value is indistinguishable from row data for `{:dot, ...}`'s own
  # resolution below, no special-casing needed there. A malformed JSON
  # string raises `:json`'s own exception -- caught and re-raised with a
  # clear, Scry-specific message, the same "let the stdlib's own error
  # surface as an ordinary, clearly-worded error" pattern `handle_token
  # (:DATE, ...)`/`handle_token(:SIGIL, ...)` already establish
  # elsewhere in this codebase (`Scry.Core.Actions`' own moduledoc).
  defp cast_to_json(s) when is_binary(s) do
    :json.decode(s)
  rescue
    _ -> raise ArgumentError, "json(...) could not parse this value as JSON: #{inspect(s)}"
  end

  defp cast_to_json(other) do
    raise ArgumentError, "json(...) only applies to a String value, got: #{inspect(other)}"
  end

  defp project_all(
         rows,
         select_items,
         own_name,
         scope,
         params,
         with_bindings,
         engine_module,
         conn
       ) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case project(row, select_items, own_name, scope, params, with_bindings, engine_module, conn) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # Halts on the first `:skip` -- once one `REQUIRED` nested query is
  # empty for this row, the whole row is already guaranteed dropped, so
  # there's no reason to keep evaluating the rest of the body items
  # (including, potentially, other expensive nested queries). This also
  # gives correct AND-across-multiple-`REQUIRED`-children semantics for
  # free: a row with two `REQUIRED` nested selects is only kept if
  # *both* are non-empty, matching how a SQL row surviving a chain of
  # `INNER JOIN`s needs every one of them to match. `:omit` (lang_spec
  # §5.3/§9's `IF $<param>`) is a different, weaker outcome than
  # `:skip` -- it drops just *this one item's own key* from the
  # projected row, not the whole row, so it `:cont`s rather than
  # `:halt`s.
  defp project(row, select_items, own_name, scope, params, with_bindings, engine_module, conn) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_item(item, row, own_name, scope, params, with_bindings, engine_module, conn) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :omit -> {:cont, {:ok, acc}}
        :skip -> {:halt, :skip}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_item(
         {:field, path},
         row,
         _own_name,
         scope,
         _params,
         _with_bindings,
         _engine_module,
         _conn
       ) do
    {:ok, List.last(path), get_path(row, scope, path)}
  end

  # lang_spec.md §9's "Computed fields" (`<alias>: <expression>`) --
  # `resolve_rhs/4` already knows how to evaluate the whole `expr()`
  # tree (it's the same function a comparison's own right-hand side
  # goes through), scope-aware, so a computed field can reference an
  # enclosing row exactly like a correlated `where` predicate can.
  defp project_item(
         {:computed, alias_name, expr},
         row,
         _own_name,
         scope,
         params,
         _with_bindings,
         _engine_module,
         _conn
       ) do
    {:ok, alias_name, resolve_rhs(expr, row, scope, params)}
  end

  # `nil`/`false` are the only falsy values (Scry's own "no implicit
  # coercion" design principle, lang_spec.md §4/§7, extended to this one
  # truthiness check the same way -- not, say, `0` or `""` too, unlike
  # some scripting languages' looser convention). Omits the key entirely
  # when falsy, matching GraphQL's own `@include`/`@skip` semantics this
  # construct is modeled on -- not a `nil`-valued key, which would be a
  # real, distinguishable difference to anything consuming the result
  # (`Map.has_key?/2` would say `true` for a present-but-null field,
  # `false` for an omitted one).
  defp project_item(
         {:field, path, {:param, _} = condition},
         row,
         _own_name,
         scope,
         params,
         _with_bindings,
         _engine_module,
         _conn
       ) do
    case resolve_rhs(condition, row, scope, params) do
      falsy when falsy in [nil, false] -> :omit
      _truthy -> {:ok, List.last(path), get_path(row, scope, path)}
    end
  end

  # `[{own_name, row} | scope]` -- the enclosing row becomes the nearest
  # entry in the *nested* query's own scope chain, so its own `where`
  # (and `order_by`) can reach it via `get_path/3` above, multiple
  # nesting levels deep if needed (each level just prepends its own
  # entry before recursing). `params` passes straight through unchanged
  # -- external parameters are the same map for the whole query
  # submission, regardless of nesting depth, unlike `scope`, which grows
  # per level. `{:ok, []} when required` is the one place `REQUIRED`
  # actually does anything -- everywhere else in this module,
  # `query.required` is simply never read (see this module's own
  # moduledoc, and `Query`'s).
  defp project_item(
         %Query{required: required} = nested,
         row,
         own_name,
         scope,
         params,
         with_bindings,
         engine_module,
         conn
       ) do
    nested
    |> run([{own_name, row} | scope], params, with_bindings, engine_module, conn)
    |> drain_result()
    |> case do
      {:ok, []} when required -> :skip
      {:ok, nested_rows} -> {:ok, List.last(nested.source), nested_rows}
      {:error, _} = err -> err
    end
  end

  defp project_item(
         {:variant, _} = item,
         _row,
         _own_name,
         _scope,
         _params,
         _with_bindings,
         _engine_module,
         _conn
       ) do
    {:error, {:unsupported_body_item, item}}
  end

  # `havings` filters *groups*, before that group's own `select`
  # projection -- lang_spec.md §5.2's own modifier order ("group by ->
  # having -> distinct -> order by -> limit"), and matches SQL: a group
  # that fails `HAVING` never gets projected at all, not projected-then-
  # discarded.
  #
  # `grouped` is `[{active_fields, member_rows}]`, not a bare list of
  # member-row-lists -- `run_grouped/6`'s own `group_levels/2` is what
  # produces more than one entry per distinct source row set (ROLLUP/
  # CUBE only; `:plain` mode's single level makes this identical to
  # passing `groups` directly, byte-for-byte, since `active_fields ==
  # query.group_bys` always then). `active_fields` flows into `project_
  # group/8` only to compute `rolled_up` (below) -- everything else
  # about a group's own projection is unaffected by which level
  # produced it.
  defp project_groups(query, grouped, own_name, scope, params, engine_module, conn) do
    Enum.reduce_while(grouped, {:ok, []}, fn {active_fields, member_rows}, {:ok, acc} ->
      if having_matches?(query.havings, member_rows, scope, params) do
        rolled_up = query.group_bys -- active_fields

        case project_group(
               query.select,
               member_rows,
               rolled_up,
               own_name,
               scope,
               params,
               engine_module,
               conn
             ) do
          {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp having_matches?(havings, member_rows, scope, params),
    do: Enum.all?(havings, &eval_group_predicate(&1, member_rows, scope, params))

  defp project_group(
         select_items,
         member_rows,
         rolled_up,
         own_name,
         scope,
         params,
         engine_module,
         conn
       ) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_group_item(
             item,
             member_rows,
             rolled_up,
             own_name,
             scope,
             params,
             engine_module,
             conn
           ) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # `path in rolled_up` -- a ROLLUP/CUBE column not active at this
  # group's own level -- projects `nil` (this module's own moduledoc
  # has the standard-SQL-convention/`GROUPING()` caveat). `rolled_up`
  # is always `[]` in `:plain` mode (`project_groups/7`'s own comment),
  # so this is an unconditional no-op there -- the plain `get_path`
  # resolution below, unchanged from before ROLLUP/CUBE existed. An
  # ordinary `if`, not a guard -- `rolled_up` is a runtime list, not a
  # compile-time literal, so `in` can't appear in a guard here at all
  # (confirmed by the compiler itself refusing it, not assumed).
  defp project_group_item(
         {:field, path},
         member_rows,
         rolled_up,
         _own_name,
         scope,
         _params,
         _em,
         _conn
       ) do
    if path in rolled_up do
      {:ok, List.last(path), nil}
    else
      {:ok, List.last(path), get_path(representative(member_rows), scope, path)}
    end
  end

  defp project_group_item(
         {:computed, alias_name, expr},
         member_rows,
         _rolled_up,
         _own_name,
         scope,
         params,
         _engine_module,
         _conn
       ) do
    {:ok, alias_name, resolve_group_rhs(expr, member_rows, scope, params)}
  end

  # Nested `SELECT`, conditional `{:field, path, condition}`, and
  # `{:variant, _}` body items are all real, valid `Query.body_item()`
  # shapes -- just not supported *inside a grouped/aggregate query's own
  # select* this increment (per-group nested fetch, and what "IF
  # $param" even means against a group rather than a single row, are
  # both real open questions, not obvious defaults to pick silently). A
  # clear, tagged error here rather than a crash or a silently wrong
  # result -- same posture `project_item`'s own `{:variant, _}` clause
  # already has.
  defp project_group_item(item, _member_rows, _rolled_up, _own_name, _scope, _params, _em, _conn),
    do: {:error, {:unsupported_grouped_body_item, item}}

  # ---- Window functions (lang_spec.md §5.5/§5.8) --------------------------
  #
  # Unlike every other `expr()` tag, a `{:window, ...}` node's value
  # depends on more than the current row -- it needs the *whole* query's
  # own filtered row set (partitioned, then ordered within each
  # partition). `run_plain/8` computes every window function's own value
  # list *before* projection (`compute_window_values/4`), then folds
  # each value onto its own row under a synthetic `{:field, [key]}`
  # reference (`window_key/1`) that the *rewritten* `select`
  # (`collect_and_rewrite_window_calls/1`) uses in place of the original
  # `{:window, ...}` node -- so `project_all`/`resolve_rhs` and every
  # other existing resolver need zero awareness of window functions at
  # all; by the time they run, a window function's own value is already
  # an ordinary per-row field. This is a deliberate design choice, not
  # an accident of implementation order: the alternative (threading a
  # new "this row's own precomputed window values" parameter through
  # `resolve_rhs/4` and every one of its recursive call sites --
  # `{:arith, ...}`, `{:when, ...}`, `{:call, ...}`'s own args, `{:dot,
  # ...}`'s own base) would ripple through this entire module for no
  # real benefit over the much smaller "rewrite the AST, augment the
  # rows" pre-pass here.
  #
  # `window_key/1`'s own synthetic field name (`"0_scry_window_#{n}"`)
  # is provably collision-proof with a real field name, not just
  # unlikely to collide -- `priv/grammar.aether`'s own `field_name :=
  # IDENT | ESCAPED_IDENT` are both `[[:alpha:]_][[:alnum:]_]*` shaped,
  # so a real field name can never start with a digit.
  #
  # Combined with a real `GROUP BY`/aggregate query (`query.group_mode
  # == :plain` only -- `ROLLUP`/`CUBE` combined with a window function
  # still raises a clear "not supported yet" from `run/6`, a deliberate
  # gap, not a silent mishandling), `run_grouped_with_windows/7` (below
  # `run_grouped/6`) reuses this exact same collect/rewrite/augment
  # machinery a second time, against the already-grouped/aggregated
  # *output* rows rather than raw filtered ones -- its own moduledoc
  # comment has the full reasoning. Only reachable from `select` at the
  # grammar level to begin with (`predicate_lhs`/
  # `in_lhs`, and `comparison`'s own `right`/`right_field`/`items`/
  # `items_expr` alternatives, never reference `window_call`/`primary`
  # directly), so a window function can never actually reach `where`/
  # `having`/`group by` in a valid parse tree in the first place --
  # confirmed by tracing every grammar rule that reaches `expression`,
  # not assumed.

  # Walks `select`, collecting every `{:window, ...}` node in pre-order
  # and replacing each with a synthetic field reference, in one pass
  # (`Enum.map_reduce/3` threading `{next_index, collected_windows}`) --
  # not two separate collect-then-rewrite passes, which could disagree
  # on ordering. Recurses into exactly the same `expr()` shapes
  # `expr_has_aggregate_call?/1` above does (`{:arith, ...}`, `{:when,
  # ...}`'s own clauses/else, `{:call, ...}`'s own args, `{:distinct,
  # ...}`, `{:dot, ...}`'s own base) -- a window call's own inner
  # `call`/`partition_by`/`order_bys`/`frame` are *not* further
  # recursed into (nested window-in-window isn't a documented
  # requirement; left undefined/best-effort, not explicitly guarded
  # against). Returns `{[], query.select}` (the *original* list,
  # untouched) when there's no window call anywhere -- confirmed by
  # construction, not just by convention, since `rewrite_body_item/2`'s
  # own fallback clause returns its argument unchanged.
  defp collect_and_rewrite_window_calls(select) do
    {rewritten, {_next_index, windows}} = Enum.map_reduce(select, {0, []}, &rewrite_body_item/2)
    {Enum.reverse(windows), rewritten}
  end

  defp rewrite_body_item({:computed, alias_name, expr}, acc) do
    {rewritten_expr, acc} = rewrite_expr(expr, acc)
    {{:computed, alias_name, rewritten_expr}, acc}
  end

  defp rewrite_body_item(other, acc), do: {other, acc}

  defp rewrite_expr(
         {:window, _call, _partition_by, _order_bys, _frame} = window,
         {index, windows}
       ) do
    {{:field, [window_key(index)]}, {index + 1, [window | windows]}}
  end

  defp rewrite_expr({:arith, op, left, right}, acc) do
    {left, acc} = rewrite_expr(left, acc)
    {right, acc} = rewrite_expr(right, acc)
    {{:arith, op, left, right}, acc}
  end

  defp rewrite_expr({:when, clauses, else_expr}, acc) do
    {clauses, acc} =
      Enum.map_reduce(clauses, acc, fn {predicate, then_expr}, acc ->
        {then_expr, acc} = rewrite_expr(then_expr, acc)
        {{predicate, then_expr}, acc}
      end)

    {else_expr, acc} = rewrite_expr(else_expr, acc)
    {{:when, clauses, else_expr}, acc}
  end

  defp rewrite_expr({:call, name, args}, acc) do
    {args, acc} = Enum.map_reduce(args, acc, &rewrite_expr/2)
    {{:call, name, args}, acc}
  end

  defp rewrite_expr({:distinct, expr}, acc) do
    {expr, acc} = rewrite_expr(expr, acc)
    {{:distinct, expr}, acc}
  end

  defp rewrite_expr({:dot, base, path}, acc) do
    {base, acc} = rewrite_expr(base, acc)
    {{:dot, base, path}, acc}
  end

  defp rewrite_expr(other, acc), do: {other, acc}

  defp window_key(index), do: "0_scry_window_#{index}"

  # Zero window calls -> `filtered` unchanged, no augmentation, no
  # per-row work at all.
  defp augment_with_window_values(filtered, [], _scope, _params), do: filtered

  defp augment_with_window_values(filtered, windows, scope, params) do
    # One `values` list per window call, each aligned index-for-index
    # with `filtered` (`compute_window_values/4`'s own contract) -- for
    # each row, pick out that row's own value from each window's list
    # by its position and stash it under that window's own synthetic
    # key. Simple, not the most efficient possible shape (an `Enum.at/2`
    # per row per window) -- the same "correct, not necessarily
    # efficient" posture this module's own moduledoc already documents
    # for `WITH`'s own re-fetch cost and `REQUIRED`'s own re-fetch cost.
    keyed_value_lists =
      windows
      |> Enum.with_index()
      |> Enum.map(fn {window, index} ->
        {window_key(index), compute_window_values(window, filtered, scope, params)}
      end)

    filtered
    |> Enum.with_index()
    |> Enum.map(fn {row, row_index} ->
      Enum.reduce(keyed_value_lists, row, fn {key, values}, acc ->
        Map.put(acc, key, Enum.at(values, row_index))
      end)
    end)
  end

  # Aligned index-for-index with `filtered_rows` -- partitions (tracking
  # each row's own original index), sorts each partition via the
  # *existing* `sorts_before?/4` (reused directly, the same generic
  # `[{path, direction}]`-shaped comparator `sort_rows/3` above already
  # uses), computes each row's own value via `window_value/9`, then
  # reassembles by original index so the result lines up with
  # `filtered_rows` regardless of partition order.
  defp compute_window_values(
         {:window, {:call, name, args}, partition_by, order_bys, frame},
         filtered_rows,
         scope,
         params
       ) do
    filtered_rows
    |> Enum.with_index()
    |> Enum.group_by(fn {row, _original_index} ->
      Enum.map(partition_by, &get_path(row, scope, &1))
    end)
    |> Enum.flat_map(fn {_partition_key, indexed_rows} ->
      sorted_indexed =
        Enum.sort(indexed_rows, fn {a, _}, {b, _} -> sorts_before?(a, b, order_bys, scope) end)

      sorted_rows = Enum.map(sorted_indexed, &elem(&1, 0))
      n = length(sorted_rows)

      sorted_indexed
      |> Enum.with_index()
      |> Enum.map(fn {{_row, original_index}, pos} ->
        value = window_value(name, args, sorted_rows, pos, n, order_bys, frame, scope, params)
        {original_index, value}
      end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # `row_number()`/`rank()` (lang_spec §5.5: "Ranking functions...
  # ignore frame entirely") -- zero arguments, validated explicitly
  # (a clear error, not a silently-ignored extra argument).
  defp window_value("row_number", [], _sorted_rows, pos, _n, _order_bys, _frame, _scope, _params),
    do: pos + 1

  defp window_value(
         "row_number",
         args,
         _sorted_rows,
         _pos,
         _n,
         _order_bys,
         _frame,
         _scope,
         _params
       ) do
    raise ArgumentError, "row_number()/0 expects no arguments, got #{length(args)}"
  end

  defp window_value("rank", [], sorted_rows, pos, _n, order_bys, _frame, scope, _params),
    do: rank_at(sorted_rows, pos, order_bys, scope)

  defp window_value("rank", args, _sorted_rows, _pos, _n, _order_bys, _frame, _scope, _params) do
    raise ArgumentError, "rank()/0 expects no arguments, got #{length(args)}"
  end

  # `first_value`/`last_value` (lang_spec §5.8) -- one argument,
  # resolved against the first/last row of the current row's own frame
  # (default: the whole partition). Deliberately **no** nil-hard-error
  # here, unlike the 10 aggregates below -- these *select* one row's
  # value, they don't *reduce* multiple values, so lang_spec's "no
  # silent nil-skipping" rule (which is about a reduction silently
  # dropping nulls) doesn't apply the same way; a genuinely nil value at
  # that position is a legitimate answer, not a skipped one.
  defp window_value("first_value", [arg], sorted_rows, pos, n, _order_bys, frame, scope, params) do
    {lo, _hi} = frame_range(frame, pos, n)
    resolve_rhs(arg, Enum.at(sorted_rows, lo), scope, params)
  end

  defp window_value(
         "first_value",
         args,
         _sorted_rows,
         _pos,
         _n,
         _order_bys,
         _frame,
         _scope,
         _params
       ) do
    raise ArgumentError, "first_value/1 expects exactly one argument, got #{length(args)}"
  end

  defp window_value("last_value", [arg], sorted_rows, pos, n, _order_bys, frame, scope, params) do
    {_lo, hi} = frame_range(frame, pos, n)
    resolve_rhs(arg, Enum.at(sorted_rows, hi), scope, params)
  end

  defp window_value(
         "last_value",
         args,
         _sorted_rows,
         _pos,
         _n,
         _order_bys,
         _frame,
         _scope,
         _params
       ) do
    raise ArgumentError, "last_value/1 expects exactly one argument, got #{length(args)}"
  end

  # Any of `@aggregate_names` used as a window function (e.g. a running
  # `sum` -- lang_spec §5.5's own "restricts an aggregate window
  # function to a frame... enables running totals / moving averages") --
  # resolved across the row's own **frame** subset, then dispatched
  # through the *existing* `eval_aggregate/5` **directly, unmodified**,
  # reusing 100% of its arity/nil-hard-error/distinct-rejection/
  # `percentile`'s own 2-arg handling for free. The single biggest reuse
  # win in this feature -- no aggregate-specific logic duplicated here
  # at all.
  defp window_value(name, args, sorted_rows, pos, n, _order_bys, frame, scope, params)
       when name in @aggregate_names do
    {lo, hi} = frame_range(frame, pos, n)
    frame_rows = slice_frame(sorted_rows, lo, hi)
    eval_aggregate(name, args, frame_rows, scope, params)
  end

  defp window_value(name, _args, _sorted_rows, _pos, _n, _order_bys, _frame, _scope, _params) do
    raise ArgumentError, "#{name}(...) is not a valid window function"
  end

  # Default frame = whole partition, *regardless of whether `order_bys`
  # is present* (lang_spec §5.5's own explicit "deliberately not SQL's
  # behavior" rule -- SQL silently narrows an implicit frame to
  # cumulative the moment `ORDER BY` is present; a cumulative/trailing
  # aggregate here always requires writing `ROWS BETWEEN` explicitly).
  defp frame_range(nil, _pos, n), do: {0, n - 1}

  defp frame_range({start_bound, end_bound}, pos, n),
    do: {resolve_bound(start_bound, pos, n), resolve_bound(end_bound, pos, n)}

  defp resolve_bound(:unbounded_preceding, _pos, _n), do: 0
  defp resolve_bound({:preceding, k}, pos, _n), do: max(0, pos - k)
  defp resolve_bound(:current_row, pos, _n), do: pos
  defp resolve_bound({:following, k}, pos, n), do: min(n - 1, pos + k)
  defp resolve_bound(:unbounded_following, _pos, n), do: n - 1

  # An inverted frame (`lo > hi`, e.g. a `ROWS BETWEEN 1 FOLLOWING AND 1
  # PRECEDING`-shaped nonsense query) yields an empty frame -- reuses
  # the *existing* empty-list aggregate answers (`sum([]) = nil`,
  # `count([]) = 0`, etc, `apply_aggregate/2` above) for free, not a
  # separate special case. `Enum.slice/2` alone isn't relied on for this
  # (its own `first > last` behavior isn't asserted here, to stay
  # independent of that), an explicit guard instead.
  defp slice_frame(_rows, lo, hi) when lo > hi, do: []
  defp slice_frame(rows, lo, hi), do: Enum.slice(rows, lo..hi)

  # SQL `RANK()` semantics: rows that tie on every `order_bys` field get
  # the *same* rank; the next distinct value's rank jumps by the number
  # of tied rows (not a plain 1-indexed sequence -- that's `row_number`,
  # above). An empty `order_bys` list makes every row vacuously "tied"
  # with its predecessor (`ties?/4`'s own `Enum.all?` over zero fields is
  # trivially true), so `rank()` with no `ORDER BY` naturally gives every
  # row rank `1` with no special-casing needed.
  defp rank_at(sorted_rows, pos, order_bys, scope),
    do: pos + 1 - count_ties_before(sorted_rows, pos, order_bys, scope)

  defp count_ties_before(_sorted_rows, 0, _order_bys, _scope), do: 0

  defp count_ties_before(sorted_rows, pos, order_bys, scope) do
    if ties?(Enum.at(sorted_rows, pos - 1), Enum.at(sorted_rows, pos), order_bys, scope) do
      1 + count_ties_before(sorted_rows, pos - 1, order_bys, scope)
    else
      0
    end
  end

  defp ties?(a, b, order_bys, scope) do
    Enum.all?(order_bys, fn {path, _direction} ->
      term_order(get_path(a, scope, path), get_path(b, scope, path)) == :eq
    end)
  end
end
