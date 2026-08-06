defmodule ScryCore.Executor do
  @moduledoc """
  Kind-agnostic query execution: given a `%ScryCore.Query{}` and any
  module implementing `ScryCore.EngineBehaviour` plus its own
  connection/config term, fetches, filters, and projects -- the
  "shared AST-walking/result-shaping utilities generic across every
  implementation of that kind" impl_spec.md §2 already describes core
  as owning. A kind-specific executor (once a real kind exists) is
  expected to call into this for the parts of a query that are still
  just core (`where`/`select`), handling only its own EP1/EP2
  contributions itself.

  A body item tagged `:variant` (`ScryCore.Query.body_item/0`) has no
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
  itself uses per distinct key.

  Only the 5 real aggregates (`sum`/`avg`/`count`/`min`/`max`) are
  actually executable (`eval_aggregate/5`) -- the rest of lang_spec
  §5.8's built-in surface (casts, `json`, window functions,
  `count(distinct ...)`) still isn't. Every aggregate hard-errors
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

  `REQUIRED` (`ScryCore.Query.required`) is read entirely by the
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
  `ScryCore.EngineBehaviour`'s own documented limitation) once per
  *surviving* outer row, because `limit`/`offset` on the outer query
  only apply after projection. This isn't a new cost *class* -- an
  uncorrelated nested query already re-runs, redundantly, once per
  outer row today -- but correlation is exactly what makes a nested
  `SELECT` worth writing as a real join at real row counts, where this
  starts to matter rather than being an unexploited memoization
  opportunity.

  **External parameters (lang_spec.md §5.7/§9).** `$name` parses to the
  placeholder `{:param, name}` (`ScryCore.Actions`) -- never resolved
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
  this codebase's established default (`ScryCore.EngineBehaviour`'s own
  moduledoc, "no pushdown ... always correct, not necessarily
  efficient"). A `WITH` binding referenced once, or only from one place,
  pays no extra cost at all; one referenced from inside a correlated
  nested `SELECT` pays the same "re-fetch per surviving outer row" cost
  `REQUIRED`'s own paragraph already documents, compounded if the
  binding is itself layered on another `WITH` binding.
  """

  alias ScryCore.{EngineBehaviour, Query, Rational}

  @typedoc "One `{ancestor_source_name, ancestor_row}` per enclosing query, nearest first."
  @type scope :: [{String.t(), EngineBehaviour.row()}]

  @typedoc "External values bound to a query's own `$name` placeholders, by name."
  @type params :: %{optional(String.t()) => term()}

  @doc """
  Executes `query` against `engine_module` (a module implementing
  `ScryCore.EngineBehaviour`) using `conn`, resolving any `$name`
  placeholder against `params`. Returns one projected result row per
  source row surviving every predicate in `query.wheres` (combined
  with `and`), sorted, deduped, and paginated per `query.order_bys`/
  `query.distinct`/`query.limit`/`query.offset` -- or, if `query` uses
  `GROUP BY` or a function call anywhere in its `select`/`havings`, one
  row per group (or one flat-aggregate row with no explicit `GROUP BY`)
  instead. See this module's own moduledoc for the exact pipeline order,
  the correlation/`REQUIRED`/external-parameter semantics, and the full
  `GROUP BY`/`HAVING`/aggregate-function story.
  """
  @spec run(Query.t(), module(), term(), params()) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  def run(%Query{} = query, engine_module, conn, params \\ %{}),
    do: run(query, [], params, query.with_bindings, engine_module, conn)

  @spec run(Query.t(), scope(), params(), %{String.t() => Query.t()}, module(), term()) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  defp run(%Query{} = query, scope, params, with_bindings, engine_module, conn) do
    with {:ok, rows} <- fetch_rows(query, scope, params, with_bindings, engine_module, conn) do
      filtered = Enum.filter(rows, &matches_all?(&1, query.wheres, scope, params))
      own_name = List.last(query.source)

      if aggregate_query?(query) do
        run_grouped(query, filtered, own_name, scope, params, engine_module, conn)
      else
        run_plain(query, filtered, own_name, scope, params, with_bindings, engine_module, conn)
      end
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
  # Falls through to the real `fetch/2` for any multi-segment source (a
  # `WITH` name is always a single bare identifier, lang_spec §9's own
  # grammar) or a single-segment one that isn't a declared binding --
  # deliberately not an error: there's no distinguishing sigil the way a
  # `FRAGMENT` spread's own `...` has, so an unrecognized bare name is
  # just assumed to be a real source (`Query`'s own moduledoc).
  defp fetch_rows(%Query{source: [name]}, scope, params, with_bindings, engine_module, conn) do
    case Map.fetch(with_bindings, name) do
      {:ok, bound_query} -> run(bound_query, scope, params, with_bindings, engine_module, conn)
      :error -> engine_module.fetch(conn, [name])
    end
  end

  defp fetch_rows(%Query{source: source}, _scope, _params, _with_bindings, engine_module, conn),
    do: engine_module.fetch(conn, source)

  # Today's ungrouped path, unchanged -- extracted verbatim so
  # `aggregate_query?/1` saying `false` is provably a no-op against this
  # module's own pre-existing behavior for any query that doesn't use
  # `GROUP BY` or a function call anywhere.
  defp run_plain(query, filtered, own_name, scope, params, with_bindings, engine_module, conn) do
    sorted = sort_rows(filtered, query.order_bys, scope)

    with {:ok, projected} <-
           project_all(
             sorted,
             query.select,
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
    groups = group_rows(filtered, query.group_bys, scope)

    with {:ok, projected} <-
           project_groups(query, groups, own_name, scope, params, engine_module, conn) do
      {:ok,
       projected
       |> sort_rows(query.order_bys, [])
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
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

  # A query needs grouped execution when it either has a real `GROUP BY`,
  # or uses a function call anywhere in its own `select`/`havings` --
  # *any* call, not just the 5 real aggregates this module actually
  # executes (`eval_aggregate/5`'s own comment has the reasoning: an
  # unsupported/unknown function name still needs to land in the grouped
  # path to get a clear error there, rather than silently falling through
  # to `run_plain/6`'s per-row `resolve_rhs/4`, which has no clause for
  # `{:call, ...}` at all and would crash with an opaque
  # `FunctionClauseError` instead).
  defp aggregate_query?(query),
    do:
      query.group_bys != [] or select_has_call?(query.select) or havings_have_call?(query.havings)

  defp select_has_call?(items), do: Enum.any?(items, &body_item_has_call?/1)

  defp body_item_has_call?({:computed, _alias, expr}), do: expr_has_call?(expr)
  defp body_item_has_call?(_other), do: false

  defp havings_have_call?(havings), do: Enum.any?(havings, &predicate_has_call?/1)

  defp predicate_has_call?({:cmp, _op, lhs, rhs}), do: lhs_has_call?(lhs) or expr_has_call?(rhs)

  defp predicate_has_call?({:in, lhs, values}),
    do: lhs_has_call?(lhs) or Enum.any?(values, &expr_has_call?/1)

  defp predicate_has_call?({:and, l, r}), do: predicate_has_call?(l) or predicate_has_call?(r)
  defp predicate_has_call?({:or, l, r}), do: predicate_has_call?(l) or predicate_has_call?(r)
  defp predicate_has_call?({:not, p}), do: predicate_has_call?(p)

  defp lhs_has_call?({:call, _name, _args}), do: true
  defp lhs_has_call?(path) when is_list(path), do: false

  defp expr_has_call?({:call, _name, _args}), do: true
  defp expr_has_call?({:arith, _op, l, r}), do: expr_has_call?(l) or expr_has_call?(r)

  defp expr_has_call?({:when, clauses, else_expr}) do
    Enum.any?(clauses, fn {predicate, expr} ->
      predicate_has_call?(predicate) or expr_has_call?(expr)
    end) or expr_has_call?(else_expr)
  end

  defp expr_has_call?(_other), do: false

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
  defp eval_predicate({:cmp, op, lhs, rhs}, row, scope, params) do
    left = resolve_predicate_lhs(lhs, row, scope)

    case resolve_rhs(rhs, row, scope, params) do
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  # Each element resolved the same way a comparison's own right-hand
  # side is -- `in [$a, $b]`/`in [orders.status]` work for exactly the
  # same reason `= $a`/`= orders.status` do, not a separate mechanism.
  defp eval_predicate({:in, lhs, values}, row, scope, params) do
    resolve_predicate_lhs(lhs, row, scope) in Enum.map(
      values,
      &resolve_rhs(&1, row, scope, params)
    )
  end

  defp eval_predicate({:and, l, r}, row, scope, params),
    do: eval_predicate(l, row, scope, params) and eval_predicate(r, row, scope, params)

  defp eval_predicate({:or, l, r}, row, scope, params),
    do: eval_predicate(l, row, scope, params) or eval_predicate(r, row, scope, params)

  defp eval_predicate({:not, p}, row, scope, params),
    do: not eval_predicate(p, row, scope, params)

  # `predicate()`'s own lhs is `[String.t()] | {:call, ...}`
  # (`ScryCore.Query`'s own moduledoc) -- a bare path resolves exactly as
  # it always has. A call is a real, purpose-written error here, not a
  # crash: `Query.expr()`'s own `{:call, ...}` only has real execution
  # semantics inside a grouped/aggregate context (`resolve_group_lhs/4`,
  # `run_grouped/7`), which this function -- `matches_all?/4`'s own
  # per-row `WHERE`/`WHEN` predicate evaluation -- never is. Without this
  # clause, `WHEN sum(x) > 1 THEN ...` used per-row would instead hit
  # `get_path/3`'s own missing clause for a 2-tuple path and raise an
  # opaque `FunctionClauseError` with no indication of what actually went
  # wrong.
  defp resolve_predicate_lhs({:call, name, _args}, _row, _scope) do
    raise ArgumentError,
          "#{name}(...) is an aggregate function -- only valid inside GROUP BY/HAVING or a " <>
            "flat-aggregate SELECT (lang_spec.md §5.2/§5.8), not an ordinary per-row predicate"
  end

  defp resolve_predicate_lhs(path, row, scope) when is_list(path), do: get_path(row, scope, path)

  defp compare(op, a, b), do: ordering_result(op, term_order(a, b))

  # `%Rational{}`/integer are compared exactly (cross-multiplication via
  # Rational.compare/2, ScryCore.Rational's own moduledoc) rather than
  # through Kernel's `< >`, which order structs by their raw field
  # values -- structurally consistent, but not numerically meaningful
  # for two arbitrary rationals (e.g. comparing 1/2 against 2/3 by field
  # order is not the same as comparing their magnitudes). A row's own
  # field value is plain data straight from an engine's `fetch/2`, so it
  # only ever needs this treatment when it's already an integer -- a
  # native float there isn't yet covered (lang_spec.md §4's "conversion
  # on ingest" model has no adapter-facing hook yet, a real, separate
  # gap, not something this clause papers over).
  defp term_order(%Rational{} = a, b) when is_integer(b) or is_struct(b, Rational),
    do: Rational.compare(a, b)

  defp term_order(a, %Rational{} = b) when is_integer(a), do: Rational.compare(a, b)

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
  # handles. Always routed through `ScryCore.Rational`'s own functions,
  # never Kernel `+ - * /` directly, so a chain of operations stays
  # exact throughout (lang_spec.md §4: "arithmetic never drops to float
  # internally") instead of only the leaves being exact.
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
  defp eval_group_predicate({:cmp, op, lhs, rhs}, member_rows, scope, params) do
    left = resolve_group_lhs(lhs, member_rows, scope, params)

    case resolve_group_rhs(rhs, member_rows, scope, params) do
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_group_predicate({:in, lhs, values}, member_rows, scope, params) do
    left = resolve_group_lhs(lhs, member_rows, scope, params)
    left in Enum.map(values, &resolve_group_rhs(&1, member_rows, scope, params))
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

  defp resolve_group_lhs({:call, name, args}, member_rows, scope, params),
    do: eval_aggregate(name, args, member_rows, scope, params)

  defp resolve_group_lhs(path, member_rows, scope, _params) when is_list(path),
    do: get_path(representative(member_rows), scope, path)

  defp resolve_group_rhs({:call, name, args}, member_rows, scope, params),
    do: eval_aggregate(name, args, member_rows, scope, params)

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
  defp eval_aggregate(name, [arg], member_rows, scope, params)
       when name in ["sum", "avg", "count", "min", "max"] do
    values = Enum.map(member_rows, &resolve_rhs(arg, &1, scope, params))

    if Enum.any?(values, &is_nil/1) do
      raise ArgumentError,
            "aggregate #{name}(...) encountered a nil value -- lang_spec.md's own " <>
              "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
              "nil-skipping); filter it out explicitly first"
    end

    apply_aggregate(name, values)
  end

  defp eval_aggregate(name, args, _member_rows, _scope, _params)
       when name in ["sum", "avg", "count", "min", "max"] do
    raise ArgumentError, "aggregate #{name}/1 expects exactly one argument, got #{length(args)}"
  end

  defp eval_aggregate(name, _args, _member_rows, _scope, _params) do
    raise ArgumentError, "unknown or unsupported function: #{inspect(name)}"
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

  # Via `term_order/2`, not Kernel `min`/`max` -- the exact same
  # `Rational`/`DateTime`/`NaiveDateTime` struct-ordering correctness
  # `term_order/2` already exists for (its own comment has the full
  # reasoning); Kernel's `min`/`max` would order two `%Rational{}`s by
  # raw field values, not by magnitude, same bug class `compare/2`
  # already avoids for ordinary comparisons.
  defp pick_min(a, b), do: if(term_order(a, b) == :lt, do: a, else: b)
  defp pick_max(a, b), do: if(term_order(a, b) == :gt, do: a, else: b)

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
    case run(nested, [{own_name, row} | scope], params, with_bindings, engine_module, conn) do
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
  defp project_groups(query, groups, own_name, scope, params, engine_module, conn) do
    Enum.reduce_while(groups, {:ok, []}, fn member_rows, {:ok, acc} ->
      if having_matches?(query.havings, member_rows, scope, params) do
        case project_group(
               query.select,
               member_rows,
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

  defp project_group(select_items, member_rows, own_name, scope, params, engine_module, conn) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_group_item(item, member_rows, own_name, scope, params, engine_module, conn) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_group_item({:field, path}, member_rows, _own_name, scope, _params, _em, _conn),
    do: {:ok, List.last(path), get_path(representative(member_rows), scope, path)}

  defp project_group_item(
         {:computed, alias_name, expr},
         member_rows,
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
  defp project_group_item(item, _member_rows, _own_name, _scope, _params, _em, _conn),
    do: {:error, {:unsupported_grouped_body_item, item}}
end
