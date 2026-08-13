defmodule Scry.Core.QueryOps do
  @moduledoc """
  The row-processing toolkit behind a flat, self-contained
  `%Scry.Core.Query{}` -- `WHERE`/`GROUP BY`/`HAVING`/aggregate
  functions, `ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`, projection,
  casts, arithmetic, and window functions. This is everything
  `Scry.Core.Executor` used to run automatically, as a mandatory
  post-fetch re-verification pass, over whatever an engine's `fetch`
  callback returned. It isn't that anymore: `Scry.Core.EngineBehaviour.
  execute/3` is authoritative now, and nothing in `Scry.Core.Executor`
  calls into this module on an engine's behalf (`Scry.Core.Executor`'s
  own moduledoc has the two narrow, structural exceptions -- a `WITH`
  binding, which has no engine of its own to ask, and a final
  correlation-column strip after nested-`SELECT` expansion -- neither
  of which second-guesses anything an engine actually computed).

  `run_flat/3` is the single public entry point: given `rows`
  (`Enumerable.t()`, already fetched by *someone* -- an engine's own
  `execute/3`, calling this at its own discretion for whatever slice
  of a query it doesn't push into its own backend natively; or `Scry.
  Core.Executor`'s own orchestration, for a `WITH`-bound source with
  no engine of its own), a flat `query`, and `params`, computes the
  entire answer `query` itself specifies and returns `{:ok,
  Enumerable.t()}` or `{:error, term()}`.

  "Flat" means what `Scry.Core.EngineBehaviour`'s own moduledoc says
  it does: no nested `%Scry.Core.Query{}` anywhere in `select`, no
  cross-scope `{:field, [ancestor, ...]}` reference left unresolved.
  This module never builds or consults a `scope` chain of its own --
  every internal helper that still threads one through (mirroring
  the shape `Scry.Core.Executor` used to have, before this split)
  always passes `[]`, which the existing `get_path/3` clauses already
  treat as a strict no-op. Nothing here calls back into any engine,
  ever -- this operates entirely over `rows` already in hand.

  See `CHANGELOG.md` for the full history of what each piece of this
  toolkit was built to do -- the "engine trust model" framing is new,
  but the per-row/per-group semantics themselves (`GROUP BY`/`ROLLUP`/
  `CUBE`, every lang_spec.md §5.8 aggregate, window functions, casts,
  `WHEN`, `json(...)`, `count(distinct ...)`, null-safety) are
  unchanged from `Scry.Core.Executor`'s own prior implementation,
  extracted here verbatim.
  """

  alias Scry.Core.{CombinedQuery, EngineBehaviour, Query, Rational, Row}
  alias Scry.Core.Executor.QueryError

  @typedoc "One `{ancestor_source_name, ancestor_row}` per enclosing query, nearest first -- always `[]` from this module's own perspective (see moduledoc)."
  @type scope :: [{String.t(), EngineBehaviour.row()}]

  @typedoc "External values bound to a query's own `$name` placeholders, by name."
  @type params :: %{optional(String.t()) => term()}

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
    "percentile",
    "rate"
  ]

  @cast_names ["string", "int", "exact", "inexact", "json"]

  # Only these 5 (of `@aggregate_names`'s full 11) are computable one row
  # at a time as a running total per group -- `percentile` needs every
  # value, sorted; `stddev*`/`var*` would need Welford's algorithm to go
  # single-pass, deliberately not attempted; `rate` needs the group's own
  # min/max timestamp, not a running fold either. Used only by the
  # streaming-eligibility family (`streaming_aggregate_plan/1` and
  # friends) and by `finalize_side/expr`'s own plan-position lookup --
  # never by the eager per-row/per-group evaluators, which handle all 11
  # via `@aggregate_names`.
  @streaming_capable_aggregate_names ~w(sum avg count min max)

  @doc """
  Computes the entire answer for a flat `query` over `rows`, resolving
  any `{:param, name}` against `params`. Returns `{:ok, Enumerable.t()}`
  of fully-realized output rows, or `{:error, term()}` for the one
  remaining structural failure this module can still raise as a value
  rather than a crash (a kind-owned `:variant` body item reaching a
  flat query -- `Scry.Core.EngineBehaviour`'s own moduledoc says why
  this should never happen for a properly-lowered kind construct, but
  it's a real, tagged error here rather than a crash if it ever does).
  A window-function/`ROLLUP`-or-`CUBE` combination this module doesn't
  support raises `ArgumentError` directly (unchanged from before this
  split), the same as an aggregate arity/nil-hard-error/unknown-name
  problem always has.

  Stays lazy (a `Stream`, not a materialized list) wherever the
  underlying query shape allows it -- a plain `WHERE`+projection query
  with no `GROUP BY`/aggregate, no window function, no real `ORDER BY`,
  no `DISTINCT` -- exactly the same eligibility `Scry.Core.Executor`
  used to decide before this split, unchanged.
  """
  @spec run_flat(Enumerable.t(), Query.t(), params()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run_flat(rows, %Query{} = query, params) do
    scope = []
    {windows, _rewritten} = collect_and_rewrite_window_calls(query.select)

    cond do
      windows != [] and aggregate_query?(query) and query.group_mode != :plain ->
        raise ArgumentError,
              "combining ROLLUP/CUBE with a window function in the same SELECT isn't " <>
                "supported yet"

      windows != [] and aggregate_query?(query) ->
        run_grouped_with_windows(query, rows, scope, params)

      aggregate_query?(query) and query.group_mode == :plain ->
        case streaming_aggregate_plan(query) do
          {:ok, plan} ->
            run_grouped_streaming(query, rows, plan, scope, params)

          :not_streamable ->
            filtered = Enum.filter(rows, &matches_all?(&1, query.wheres, scope, params))
            run_grouped(query, filtered, scope, params)
        end

      aggregate_query?(query) ->
        filtered = Enum.filter(rows, &matches_all?(&1, query.wheres, scope, params))
        run_grouped(query, filtered, scope, params)

      windows == [] and query.order_bys == [] and not query.distinct and query.limit == nil and
          select_has_call?(query.select) ->
        run_plain_parallel(query, rows, scope, params)

      windows == [] and query.order_bys == [] and not query.distinct ->
        run_plain_streaming(query, rows, scope, params)

      windows == [] and query.order_bys != [] and not query.distinct and query.limit != nil ->
        run_topk_streaming(query, rows, scope, params)

      true ->
        filtered = Enum.filter(rows, &matches_all?(&1, query.wheres, scope, params))
        run_plain(query, filtered, scope, params)
    end
  end

  @doc """
  Full-document orchestration for an engine that wants Scry's own
  generic `WITH`/nested-`SELECT`/combinator semantics applied
  automatically from inside its own `execute/3`, instead of
  translating them itself (a native `JOIN` for a correlated nested
  `SELECT`, a native CTE for a `WITH` binding, a native `UNION` for a
  combinator) -- entirely that engine's own choice to call this, never
  something `Scry.Core.Executor.run/3,4` does on its behalf. Resolves
  `WITH` bindings and combinators fully generically, and each flat
  leaf query (after resolving its own source and any correlated
  reference into `params`) via `engine_module.execute/3` -- recursing
  back into whichever engine is doing the delegating, so that engine's
  own optimizations (a real `WHERE` pushdown, say) still apply to each
  leaf.

  **Scoped narrower than the pre-pivot interpreter this replaces, in
  two documented ways, both deliberate rather than half-implemented:**
  a nested query's own correlated reference must name its *immediate*
  enclosing query, not a grandparent or higher (multi-level structural
  nesting still composes correctly via recursion; multi-level
  *correlation* to a non-immediate ancestor does not); and correlation
  is only detected in a nested query's own `wheres`, specifically a
  comparison's right-hand side (`{:field, [ancestor, field]}`,
  lang_spec's own worked example shape) -- not `select`/`order_bys`,
  and not a two-or-more-segment path under the ancestor. Both are real
  gaps versus the old interpreter's full scope-chain, kept narrow on
  purpose rather than reproducing that entire mechanism here.
  """
  @spec run_document(term(), Query.t() | CombinedQuery.t(), params(), module()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def run_document(conn, query_or_combined, params, engine_module) do
    # `with_bindings` (lang_spec.md §9's `WITH`) only ever lives on the
    # top-level `%Query{}`/`%CombinedQuery{}` a whole document parses
    # to -- a nested `%Query{}` embedded in `select` has its own field
    # default to `%{}`, never populated by the parser (confirmed
    # directly: a `WITH`-bound source referenced from *inside* a
    # nested `SELECT` fails to resolve if this isn't threaded down
    # explicitly). Captured once here, then threaded as an explicit
    # parameter through every recursive call below instead of ever
    # re-reading `query.with_bindings` from whatever nested/rewritten
    # struct happens to be in hand at that point.
    run_document(conn, query_or_combined, params, engine_module, query_or_combined.with_bindings)
  end

  @doc """
  Resolves one nested-`SELECT` body item (`nested`, already known to be
  a `%Scry.Core.Query{}`) against `outer_row`, correlating any
  `{:field, [own_name, field]}` reference in its own `wheres` to
  `outer_row`'s own value for `field` -- the identical correlation
  `run_document/4`'s own internal `expand_row/7` already performs for
  an ordinary `Scry.Core.EngineBehaviour`-based engine, exposed here as
  a standalone, reusable primitive.

  **Why this exists**: `run_flat/3` is explicitly "flat" -- this
  module's own moduledoc states it operates only "over `rows` already
  in hand," never resolving a nested `%Scry.Core.Query{}` body item at
  all (confirmed the hard way, not assumed: `Scry.Core.QueryOps.
  project_item/3` genuinely has no clause for a bare `%Query{}`, a real
  `FunctionClauseError` if one ever reaches it). A kind package whose
  own executor bypasses `EngineBehaviour` entirely (`scry_document`/
  `scry_graph`, needing the *whole* document/graph space, not one
  already-resolved source) has no way to reach `run_document/4`'s own
  whole-query orchestration either, since that function fetches every
  flat leaf via `engine_module.execute/3` -- a contract neither
  package's own bespoke `conn` implements. This function factors out
  just the correlation-rewrite step `run_document/4` already has
  (`rewrite_correlation/3`, this module's own private helper) so such a
  package can resolve a nested `SELECT` sibling of its own pseudo-field
  body items correctly, without duplicating correlation semantics
  (`AND`/`OR`/`NOT`/`IN` nesting included) independently.

  `fetch_fn` is how the caller actually runs the (correlation-rewritten)
  query against its own backend once rewritten -- typically `&__MODULE__.
  run(&1, conn, &2)`, recursing back into the *caller's own* top-level
  entry point (so a nested `SELECT` can itself contain another nested
  `SELECT`, or the caller's own pseudo-fields, fully recursively, for
  free) rather than a new, parallel resolution path.
  """
  @spec resolve_correlated_nested(
          Query.t(),
          EngineBehaviour.row(),
          String.t(),
          params(),
          (Query.t(), params() -> {:ok, Enumerable.t()} | {:error, term()})
        ) :: {:ok, [EngineBehaviour.row()]} | {:error, term()}
  def resolve_correlated_nested(
        %Query{wheres: wheres} = nested,
        outer_row,
        own_name,
        params,
        fetch_fn
      ) do
    {rewritten_wheres, extra_params} = rewrite_correlation(wheres, own_name, outer_row)
    rewritten = %{nested | wheres: rewritten_wheres}

    with {:ok, rows} <- fetch_fn.(rewritten, Map.merge(params, extra_params)) do
      {:ok, Enum.map(Enum.to_list(rows), &to_plain_row/1)}
    end
  end

  defp run_document(
         conn,
         %CombinedQuery{op: op, left: left, right: right},
         params,
         engine_module,
         with_bindings
       ) do
    with {:ok, left_rows} <- drain_document(conn, left, params, engine_module, with_bindings),
         {:ok, right_rows} <- drain_document(conn, right, params, engine_module, with_bindings) do
      # `combine_rows/3` does real structural-equality set operations
      # (`Enum.uniq/1`, `MapSet.member?/2`) -- a `Scry.Core.Row`'s own
      # equality is tied to its *positional* shape (its own `index`),
      # not just its logical field values, so two otherwise-identical
      # rows from engines that happened to build their own index in a
      # different column order would wrongly compare unequal. Every
      # `CombinedQuery` result is always plain maps, regardless of
      # what either side's own engine chose to return internally.
      {:ok,
       combine_rows(
         op,
         Enum.map(left_rows, &to_plain_row/1),
         Enum.map(right_rows, &to_plain_row/1)
       )}
    end
  end

  defp run_document(conn, %Query{} = query, params, engine_module, with_bindings) do
    case Enum.split_with(query.select, &match?(%Query{}, &1)) do
      {[], _shell_select} ->
        resolve_source(conn, query, params, engine_module, with_bindings)

      {nested_items, shell_select} ->
        run_with_nested_selects(
          conn,
          query,
          shell_select,
          nested_items,
          params,
          engine_module,
          with_bindings
        )
    end
  end

  defp drain_document(conn, query_or_combined, params, engine_module, with_bindings) do
    case run_document(conn, query_or_combined, params, engine_module, with_bindings) do
      {:ok, rows} -> {:ok, Enum.to_list(rows)}
      {:error, _} = err -> err
    end
  rescue
    e in QueryError -> {:error, e.reason}
  end

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

  defp to_plain_row(%Row{} = row), do: Row.to_map(row)
  defp to_plain_row(row), do: row

  # A query whose own `source` is exactly `[name]` for a declared
  # `WITH` binding has no real engine-side existence at all -- it's
  # resolved by running the bound query (fresh, every time, no
  # caching -- lang_spec.md §9's own documented cost tradeoff,
  # unchanged) and treating its own result rows as `query`'s own
  # source, via `run_flat/3` (there's no engine left to delegate the
  # rest of `query` to once its source is already-materialized rows).
  # Any other source is a real one -- handed to `engine_module.
  # execute/3` whole, unmodified.
  defp resolve_source(conn, %Query{source: [name]} = query, params, engine_module, with_bindings) do
    case Map.fetch(with_bindings, name) do
      {:ok, bound_query} ->
        with {:ok, rows} <-
               drain_document(conn, bound_query, params, engine_module, with_bindings) do
          run_flat(rows, query, params)
        end

      :error ->
        engine_module.execute(conn, query, params)
    end
  end

  defp resolve_source(conn, query, params, engine_module, _with_bindings),
    do: engine_module.execute(conn, query, params)

  # The shell query gets `distinct`/`limit`/`offset` stripped and any
  # column a nested item's own correlation needs appended to `select`
  # -- both deferred to *this* function's own final step instead,
  # since a `REQUIRED` nested query coming back empty can still drop
  # an outer row *after* the engine has already answered, and
  # `distinct`/pagination must see the row set that survives that,
  # not the row set before it (`Scry.Core.Query`'s own moduledoc,
  # "Correlation and joins").
  defp run_with_nested_selects(
         conn,
         query,
         shell_select,
         nested_items,
         params,
         engine_module,
         with_bindings
       ) do
    own_name = List.last(query.source)
    extra_columns = correlation_columns(nested_items, own_name, shell_select)

    shell_query = %{
      query
      | select: shell_select ++ extra_columns,
        distinct: false,
        limit: nil,
        offset: nil
    }

    with {:ok, shell_rows} <-
           resolve_source(conn, shell_query, params, engine_module, with_bindings) do
      shell_rows
      |> Enum.reduce_while({:ok, []}, fn outer_row, {:ok, acc} ->
        case expand_row(
               conn,
               outer_row,
               nested_items,
               own_name,
               params,
               engine_module,
               with_bindings
             ) do
          {:ok, expanded} -> {:cont, {:ok, [strip_extra_columns(expanded, extra_columns) | acc]}}
          :skip -> {:cont, {:ok, acc}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, acc} ->
          {:ok,
           acc
           |> Enum.reverse()
           |> maybe_dedupe(query.distinct)
           |> paginate(query.limit, query.offset)}

        err ->
          err
      end
    end
  end

  defp correlation_columns(nested_items, own_name, shell_select) do
    already_selected =
      MapSet.new(shell_select, fn
        {:field, path} -> List.last(path)
        {:computed, alias_name, _expr} -> alias_name
      end)

    nested_items
    |> Enum.flat_map(fn %Query{wheres: wheres} ->
      Enum.flat_map(wheres, &correlation_refs(&1, own_name))
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in already_selected))
    |> Enum.map(&{:field, [&1]})
  end

  defp correlation_refs({:cmp, _op, lhs, rhs}, own_name),
    do: correlation_ref(lhs, own_name) ++ correlation_ref(rhs, own_name)

  defp correlation_refs({:in, lhs, values}, own_name) when is_list(values),
    do: correlation_ref(lhs, own_name) ++ Enum.flat_map(values, &correlation_ref(&1, own_name))

  defp correlation_refs({:in, lhs, list_expr}, own_name),
    do: correlation_ref(lhs, own_name) ++ correlation_ref(list_expr, own_name)

  defp correlation_refs({:and, l, r}, own_name),
    do: correlation_refs(l, own_name) ++ correlation_refs(r, own_name)

  defp correlation_refs({:or, l, r}, own_name),
    do: correlation_refs(l, own_name) ++ correlation_refs(r, own_name)

  defp correlation_refs({:not, p}, own_name), do: correlation_refs(p, own_name)
  defp correlation_refs(_other, _own_name), do: []

  defp correlation_ref({:field, [ancestor, field]}, own_name) when ancestor == own_name,
    do: [field]

  defp correlation_ref(_other, _own_name), do: []

  defp expand_row(conn, outer_row, nested_items, own_name, params, engine_module, with_bindings) do
    Enum.reduce_while(nested_items, {:ok, outer_row}, fn nested, {:ok, row_acc} ->
      case run_nested(conn, nested, outer_row, own_name, params, engine_module, with_bindings) do
        {:ok, []} ->
          if nested.required do
            {:halt, :skip}
          else
            {:cont, {:ok, put_field(row_acc, List.last(nested.source), [])}}
          end

        {:ok, nested_rows} ->
          plain_nested_rows = Enum.map(nested_rows, &to_plain_row/1)
          {:cont, {:ok, put_field(row_acc, List.last(nested.source), plain_nested_rows)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  # A nested-`SELECT`/window-function result appends a synthetic key no
  # fixed-shape `Scry.Core.Row` can represent -- converts to a plain
  # map on first write (`Row.to_map/1`), same as any other genuinely-
  # new-field augmentation this toolkit does. A no-op for a row that's
  # already a plain map.
  defp put_field(%Row{} = row, key, value), do: row |> Row.to_map() |> Map.put(key, value)
  defp put_field(row, key, value), do: Map.put(row, key, value)

  defp run_nested(
         conn,
         %Query{wheres: wheres} = nested,
         outer_row,
         own_name,
         params,
         engine_module,
         with_bindings
       ) do
    {rewritten_wheres, extra_params} = rewrite_correlation(wheres, own_name, outer_row)
    rewritten = %{nested | wheres: rewritten_wheres}
    drain_document(conn, rewritten, Map.merge(params, extra_params), engine_module, with_bindings)
  end

  defp rewrite_correlation(wheres, own_name, outer_row) do
    {rewritten, {_next, extra_params}} =
      Enum.map_reduce(
        wheres,
        {0, %{}},
        &rewrite_predicate_correlation(&1, own_name, outer_row, &2)
      )

    {rewritten, extra_params}
  end

  defp rewrite_predicate_correlation({:cmp, op, lhs, rhs}, own_name, outer_row, acc) do
    {lhs2, acc} = rewrite_side_correlation(lhs, own_name, outer_row, acc)
    {rhs2, acc} = rewrite_side_correlation(rhs, own_name, outer_row, acc)
    {{:cmp, op, lhs2, rhs2}, acc}
  end

  defp rewrite_predicate_correlation({:in, lhs, values}, own_name, outer_row, acc)
       when is_list(values) do
    {lhs2, acc} = rewrite_side_correlation(lhs, own_name, outer_row, acc)

    {values2, acc} =
      Enum.map_reduce(values, acc, &rewrite_side_correlation(&1, own_name, outer_row, &2))

    {{:in, lhs2, values2}, acc}
  end

  defp rewrite_predicate_correlation({:in, lhs, list_expr}, own_name, outer_row, acc) do
    {lhs2, acc} = rewrite_side_correlation(lhs, own_name, outer_row, acc)
    {list_expr2, acc} = rewrite_side_correlation(list_expr, own_name, outer_row, acc)
    {{:in, lhs2, list_expr2}, acc}
  end

  defp rewrite_predicate_correlation({:and, l, r}, own_name, outer_row, acc) do
    {l2, acc} = rewrite_predicate_correlation(l, own_name, outer_row, acc)
    {r2, acc} = rewrite_predicate_correlation(r, own_name, outer_row, acc)
    {{:and, l2, r2}, acc}
  end

  defp rewrite_predicate_correlation({:or, l, r}, own_name, outer_row, acc) do
    {l2, acc} = rewrite_predicate_correlation(l, own_name, outer_row, acc)
    {r2, acc} = rewrite_predicate_correlation(r, own_name, outer_row, acc)
    {{:or, l2, r2}, acc}
  end

  defp rewrite_predicate_correlation({:not, p}, own_name, outer_row, acc) do
    {p2, acc} = rewrite_predicate_correlation(p, own_name, outer_row, acc)
    {{:not, p2}, acc}
  end

  # An unresolved `{:variant, ...}` predicate (EP1(e), e.g. `search`'s
  # own `SEARCH`) has nothing for correlation rewriting to do -- it's
  # opaque to core, and `correlation_refs/2`'s own identical-shaped
  # catch-all (`defp correlation_refs(_other, _own_name), do: []`,
  # right above) already treats it the same way for the sibling
  # "does this predicate reference the ancestor at all" scan. Passed
  # through unchanged, `acc` untouched -- same "no-op" treatment every
  # other predicate-tree walker in this module now gives this shape.
  defp rewrite_predicate_correlation({:variant, _} = predicate, _own_name, _outer_row, acc),
    do: {predicate, acc}

  # `"0_scry_correlation_N"` is provably collision-proof with a real
  # `$name` param the same way `window_key/1`'s own synthetic field
  # name already is -- a real identifier can never start with a digit.
  defp rewrite_side_correlation({:field, [ancestor, field]}, own_name, outer_row, {next, extra})
       when ancestor == own_name do
    param_name = "0_scry_correlation_#{next}"

    {{:param, param_name},
     {next + 1, Map.put(extra, param_name, get_path_in(outer_row, [field]))}}
  end

  defp rewrite_side_correlation(other, _own_name, _outer_row, acc), do: {other, acc}

  defp strip_extra_columns(row, extra_columns) do
    extra_keys = Enum.map(extra_columns, fn {:field, [key]} -> key end)
    Map.drop(row, extra_keys)
  end

  # ---- Plain WHERE + projection -------------------------------------------

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

  defp expr_has_call?({:window, _call, _partition_by, _order_bys, _frame}), do: true
  defp expr_has_call?(_other), do: false

  # `select_has_call?/1` gates this path on real, measured grounds (not
  # a general "parallelize everything" default): a `select` of only
  # bare field references measured *slower* through this path than
  # through `run_plain_streaming/4` (every matching row still has to
  # cross a worker task's mailbox both ways, and that copy cost dwarfs
  # a bare field access's own near-zero per-row compute), while a
  # `select` with a real function call measured 1.4-1.5x faster (the
  # per-row compute becomes large enough to be worth the same copy
  # cost). See `Scry.Core.Executor`'s own former moduledoc history
  # (`CHANGELOG.md`) for the full measurement.
  # A fetch-level failure already surfaced before this is ever reached
  # (the engine's own `execute/3`, or orchestration's `WITH`-resolution,
  # already produced `rows` by the time `run_flat/3` is called) -- but
  # the parallel dispatch/row-processing itself (where a raised
  # `QueryError` or a hard aggregate/cast error can originate,
  # `filter_and_project_chunk/4`'s own doc has the exact cases) must
  # stay deferred until a caller actually pulls from the returned
  # `Stream`, matching `Scry.Core.Executor.run/3,4`'s own documented
  # "a lazily-discovered failure surfaces on pull, not from `run/4`
  # itself" contract -- `Stream.resource/3`'s own `start_fun`/`next_fun`
  # don't run at all until the stream is first reduced, so wrapping the
  # whole computation in one is what defers it.
  defp run_plain_parallel(query, rows, scope, params) do
    stream =
      Stream.resource(
        fn -> :pending end,
        fn
          :pending ->
            chunk_fun = &filter_and_project_chunk(&1, query, scope, params)

            projected =
              rows
              |> process_chunks_parallel(chunk_fun, &prepend_chunk/2, [])
              |> Enum.reverse()
              |> Enum.concat()
              |> paginate(query.limit, query.offset)

            {projected, :done}

          :done ->
            {:halt, :done}
        end,
        fn _state -> :ok end
      )

    {:ok, stream}
  end

  defp prepend_chunk(acc, chunk_rows), do: [chunk_rows | acc]

  defp filter_and_project_chunk(rows, query, scope, params) do
    rows
    |> Enum.filter(&matches_all?(&1, query.wheres, scope, params))
    |> Enum.map(fn row ->
      case project(query.select, row, params) do
        {:ok, projected} -> projected
        {:error, reason} -> raise QueryError, reason: reason
      end
    end)
  end

  defp run_plain_streaming(query, rows, scope, params) do
    stream =
      rows
      |> Stream.filter(&matches_all?(&1, query.wheres, scope, params))
      |> Stream.map(&project_or_raise(query.select, &1, params))
      |> apply_offset_limit_lazily(query.offset, query.limit)

    {:ok, stream}
  end

  defp apply_offset_limit_lazily(stream, nil, nil), do: stream
  defp apply_offset_limit_lazily(stream, offset, nil), do: Stream.drop(stream, offset || 0)

  defp apply_offset_limit_lazily(stream, offset, limit),
    do: stream |> Stream.drop(offset || 0) |> Stream.take(limit)

  defp project_or_raise(select_items, row, params) do
    case project(select_items, row, params) do
      {:ok, projected} -> projected
      {:error, reason} -> raise QueryError, reason: reason
    end
  end

  # Windows are computed *before* sorting/projection: each window's own
  # value list is computed once against `filtered` (`compute_window_
  # values/4`), folded onto its own row under a synthetic key, and the
  # *rewritten* `select` (referencing that key via an ordinary `{:field,
  # ...}`) is what actually gets projected -- so `project_all`/
  # `resolve_rhs` need zero awareness of window functions at all. Zero
  # window calls -> `collect_and_rewrite_window_calls/1` returns `{[],
  # query.select}`, so `select`/`augmented` below are byte-identical to
  # `query.select`/`filtered`.
  defp run_plain(query, filtered, scope, params) do
    {windows, select} = collect_and_rewrite_window_calls(query.select)
    augmented = augment_with_window_values(filtered, windows, scope, params, query.time_field)
    sorted = sort_rows(augmented, query.order_bys, scope, params)

    with {:ok, projected} <- project_all(select, sorted, params) do
      {:ok,
       projected
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  # Keeps only the `limit + offset` best-so-far rows in memory at any
  # point -- `O(limit + offset)`, not `O(n)` -- rather than materializing
  # every filtered row before sorting. `k` includes `offset` because
  # `paginate/3` below still needs to see (and then drop) those rows;
  # only `query.limit` alone would silently lose them.
  defp run_topk_streaming(query, rows, scope, params) do
    k = (query.limit || 0) + (query.offset || 0)

    # `k == 0` (a real `LIMIT 0`) needs no buffering, no comparator
    # call at all -- `insert_topk/5`'s own "buffer already full"
    # clause assumes a non-empty buffer to compare `row` against
    # (`List.last/1`), which is never true when `k` itself is 0.
    buffer =
      if k == 0 do
        []
      else
        Enum.reduce(rows, [], fn row, buffer ->
          if matches_all?(row, query.wheres, scope, params) do
            insert_topk(buffer, row, k, query.order_bys, scope, params)
          else
            buffer
          end
        end)
      end

    with {:ok, projected} <- project_all(query.select, buffer, params) do
      {:ok, paginate(projected, query.limit, query.offset)}
    end
  end

  defp insert_topk(buffer, row, k, order_bys, scope, params) when length(buffer) < k,
    do: insert_sorted(buffer, row, order_bys, scope, params)

  defp insert_topk(buffer, row, _k, order_bys, scope, params) do
    worst = List.last(buffer)

    if sorts_before?(row, worst, order_bys, scope, params) do
      buffer |> List.delete_at(-1) |> insert_sorted(row, order_bys, scope, params)
    else
      buffer
    end
  end

  defp insert_sorted(buffer, row, order_bys, scope, params) do
    {before, rest} = Enum.split_while(buffer, &sorts_before?(&1, row, order_bys, scope, params))
    before ++ [row | rest]
  end

  # ---- GROUP BY streaming aggregation (the parallel-chunked path) --------

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

  defp streaming_body_item_calls(_other), do: :not_streamable

  defp streaming_having_calls(havings) do
    Enum.reduce_while(havings, {:ok, []}, fn predicate, {:ok, acc} ->
      case streaming_predicate_calls(predicate) do
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

  # An unresolved EP1(e) `{:variant, ...}` predicate (a kind package's
  # own incomplete lowering pass -- Scry.Core.Query's own moduledoc has
  # the full shape) forces the eager path, the same as any other
  # genuinely-can't-stream construct here -- `eval_group_predicate/5`'s
  # own matching clause is what actually raises the clear, named error;
  # this clause exists purely so that error is what a caller sees,
  # rather than this function's own `FunctionClauseError` on a shape it
  # was never meant to recognize.
  defp streaming_predicate_calls({:variant, _}), do: :not_streamable

  defp combine_streaming({:ok, a}, {:ok, b}), do: {:ok, a ++ b}
  defp combine_streaming(_a, _b), do: :not_streamable

  defp streaming_side_calls(path) when is_list(path), do: {:ok, []}
  defp streaming_side_calls({:literal, _value}), do: {:ok, []}
  defp streaming_side_calls(nil), do: {:ok, []}

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

  defp run_grouped_streaming(query, rows, plan, scope, params) do
    with {:ok, groups, order} <- accumulate_groups_parallel(rows, query, plan, scope, params) do
      {:ok,
       finalize_groups(query, groups, order, scope, params, plan)
       |> sort_rows(query.order_bys, [], params)
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  defp finalize_groups(query, groups, order, scope, params, plan) do
    for key <- order,
        group_state = Map.fetch!(groups, key),
        having_matches_streaming?(query.havings, group_state, scope, params, plan) do
      finalize_grouped_row(query, group_state, scope, params, plan)
    end
  end

  @default_parallel_chunk_size 5_000
  defp parallel_chunk_size,
    do: Application.get_env(:scry_core, :parallel_chunk_size, @default_parallel_chunk_size)

  defp parallel_max_concurrency,
    do: Application.get_env(:scry_core, :parallel_max_concurrency, System.schedulers_online())

  defp accumulate_groups_parallel(rows, query, plan, scope, params) do
    {groups, order} =
      process_chunks_parallel(
        rows,
        &accumulate_chunk(&1, query, plan, scope, params),
        &merge_group_state(&1, &2, plan),
        {%{}, []}
      )

    {groups2, order2} = ensure_flat_group(query.group_bys, plan, groups, order)
    {:ok, groups2, order2}
  end

  # The shared runner behind every parallel-chunked path in this module.
  # `chunk_fun` (a batch's own row list -> that batch's own partial
  # result) and `merge_fun` (an accumulated partial result + one more
  # batch's own partial result -> the combined partial result) are the
  # only two things that differ between callers.
  defp process_chunks_parallel(rows, chunk_fun, merge_fun, initial_acc) do
    Scry.Core.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Stream.chunk_every(rows, parallel_chunk_size()),
      chunk_fun,
      ordered: true,
      max_concurrency: parallel_max_concurrency()
    )
    |> Enum.reduce_while(initial_acc, &reduce_chunk_result(&1, &2, merge_fun))
  end

  defp reduce_chunk_result({:ok, chunk_result}, acc, merge_fun),
    do: {:cont, merge_fun.(acc, chunk_result)}

  defp reduce_chunk_result({:exit, {{:nocatch, value}, stacktrace}}, _acc, _merge_fun),
    do: :erlang.raise(:throw, value, stacktrace)

  defp reduce_chunk_result({:exit, {reason, stacktrace}}, _acc, _merge_fun)
       when is_list(stacktrace),
       do: :erlang.raise(:error, reason, stacktrace)

  defp reduce_chunk_result({:exit, reason}, _acc, _merge_fun), do: exit(reason)

  defp ensure_flat_group([], plan, groups, _order) when map_size(groups) == 0 do
    aggs_tuple = plan |> Enum.map(fn {name, args} -> init_agg(name, args) end) |> List.to_tuple()
    empty_state = {%{}, aggs_tuple}

    {%{[] => empty_state}, [[]]}
  end

  defp ensure_flat_group(_group_bys, _plan, groups, order), do: {groups, order}

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

  defp merge_group_state({groups_acc, order_acc}, {groups_new, order_new}, plan) do
    {merged_groups, reversed_new_keys} =
      Enum.reduce(order_new, {groups_acc, []}, fn key, {groups, new_keys} ->
        new_state = Map.fetch!(groups_new, key)

        case Map.fetch(groups, key) do
          {:ok, existing_state} ->
            {Map.put(groups, key, merge_group(existing_state, new_state, plan)), new_keys}

          :error ->
            {Map.put(groups, key, new_state), [key | new_keys]}
        end
      end)

    {merged_groups, order_acc ++ Enum.reverse(reversed_new_keys)}
  end

  defp merge_group({rep, aggs1}, {_rep2, aggs2}, plan) do
    merged_aggs =
      plan
      |> Enum.with_index()
      |> Enum.map(fn {{name, _args}, index} ->
        merge_agg(elem(aggs1, index), elem(aggs2, index), name)
      end)
      |> List.to_tuple()

    {rep, merged_aggs}
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
      plan
      |> Enum.map(fn {name, args} ->
        update_agg(init_agg(name, args), name, args, row, scope, params)
      end)
      |> List.to_tuple()

    {row, aggs}
  end

  defp update_group({rep, aggs}, plan, row, scope, params) do
    aggs2 =
      plan
      |> Enum.with_index()
      |> Enum.map(fn {{name, args}, index} ->
        update_agg(elem(aggs, index), name, args, row, scope, params)
      end)
      |> List.to_tuple()

    {rep, aggs2}
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

  defp update_agg(_acc, name, [{:distinct, _arg}], _row, _scope, _params) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not #{name}(...)"
  end

  defp update_agg(_acc, name, args, _row, _scope, _params) do
    raise ArgumentError, "aggregate #{name}/1 expects exactly one argument, got #{length(args)}"
  end

  defp add_to_running_sum(:empty, value), do: value
  defp add_to_running_sum(existing, value), do: Rational.add(existing, value)

  defp raise_aggregate_nil_error(call_text) do
    raise ArgumentError,
          "aggregate #{call_text} encountered a nil value -- lang_spec.md's own " <>
            "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
            "nil-skipping); filter it out explicitly first"
  end

  defp having_matches_streaming?(havings, group_state, scope, params, plan),
    do: Enum.all?(havings, &eval_having_streaming?(&1, group_state, scope, params, plan))

  defp eval_having_streaming?({:cmp, op, lhs, nil}, group_state, scope, params, plan),
    do: compare(op, finalize_side(lhs, group_state, scope, params, plan), nil)

  defp eval_having_streaming?({:cmp, op, lhs, rhs}, group_state, scope, params, plan) do
    left = finalize_side(lhs, group_state, scope, params, plan)

    case finalize_side(rhs, group_state, scope, params, plan) do
      _ when is_nil(left) -> raise_null_safety_error()
      nil -> raise_null_safety_error()
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_having_streaming?({:in, lhs, values}, group_state, scope, params, plan)
       when is_list(values) do
    left = finalize_side(lhs, group_state, scope, params, plan)
    left in Enum.map(values, &finalize_side(&1, group_state, scope, params, plan))
  end

  defp eval_having_streaming?({:in, lhs, list_expr}, group_state, scope, params, plan) do
    left = finalize_side(lhs, group_state, scope, params, plan)

    case finalize_side(list_expr, group_state, scope, params, plan) do
      list when is_list(list) -> left in list
      other -> raise ArgumentError, "in ... expects a list value, got: #{inspect(other)}"
    end
  end

  defp eval_having_streaming?({:and, l, r}, group_state, scope, params, plan),
    do:
      eval_having_streaming?(l, group_state, scope, params, plan) and
        eval_having_streaming?(r, group_state, scope, params, plan)

  defp eval_having_streaming?({:or, l, r}, group_state, scope, params, plan),
    do:
      eval_having_streaming?(l, group_state, scope, params, plan) or
        eval_having_streaming?(r, group_state, scope, params, plan)

  defp eval_having_streaming?({:not, p}, group_state, scope, params, plan),
    do: not eval_having_streaming?(p, group_state, scope, params, plan)

  defp finalize_side(path, {rep, _aggs}, scope, _params, _plan) when is_list(path),
    do: get_path(rep, scope, path)

  defp finalize_side({:literal, value}, _group_state, _scope, _params, _plan), do: value

  defp finalize_side({:call, name, args}, {_rep, aggs}, _scope, _params, plan)
       when name in @streaming_capable_aggregate_names,
       do: finalize_agg(elem(aggs, agg_position(plan, name, args)), name)

  defp finalize_side(expr, {rep, _aggs}, scope, params, _plan),
    do: resolve_rhs(expr, rep, scope, params)

  defp finalize_grouped_row(query, group_state, scope, params, plan),
    do: Map.new(query.select, &finalize_body_item(&1, group_state, scope, params, plan))

  defp finalize_body_item({:field, path}, {rep, _aggs}, scope, _params, _plan),
    do: {List.last(path), get_path(rep, scope, path)}

  defp finalize_body_item({:computed, alias_name, expr}, group_state, scope, params, plan),
    do: {alias_name, finalize_expr(expr, group_state, scope, params, plan)}

  defp finalize_expr({:call, name, args}, {_rep, aggs}, _scope, _params, plan)
       when name in @streaming_capable_aggregate_names,
       do: finalize_agg(elem(aggs, agg_position(plan, name, args)), name)

  defp finalize_expr(expr, {rep, _aggs}, scope, params, _plan),
    do: resolve_rhs(expr, rep, scope, params)

  defp agg_position(plan, name, args), do: Enum.find_index(plan, &(&1 == {name, args}))

  defp finalize_agg(:empty, _name), do: nil
  defp finalize_agg(value, name) when name in ["sum", "min", "max"], do: value
  defp finalize_agg(count, "count") when is_integer(count), do: count
  defp finalize_agg(%MapSet{} = set, "count"), do: MapSet.size(set)
  defp finalize_agg({:empty, _count}, "avg"), do: nil
  defp finalize_agg({sum, count}, "avg"), do: Rational.div(sum, count)

  # ---- Eager GROUP BY / ROLLUP / CUBE (percentile/stddev*/var*, or any
  # aggregate expression wider than a bare call) -------------------------

  defp run_grouped(query, filtered, scope, params) do
    with {:ok, projected} <- grouped_base_rows(query, filtered, scope, params) do
      {:ok,
       projected
       |> sort_rows(query.order_bys, [], params)
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  defp grouped_base_rows(query, filtered, scope, params) do
    grouped =
      query.group_bys
      |> group_levels(query.group_mode)
      |> Enum.flat_map(fn active_fields ->
        filtered
        |> group_rows(active_fields, scope)
        |> Enum.map(&{active_fields, &1})
      end)

    project_groups(query, grouped, scope, params)
  end

  defp run_grouped_with_windows(query, rows, scope, params) do
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
          case accumulate_groups_parallel(rows, base_query, plan, scope, params) do
            {:ok, groups, order} ->
              {:ok, finalize_groups(base_query, groups, order, scope, params, plan)}
          end

        :not_streamable ->
          filtered = Enum.filter(rows, &matches_all?(&1, query.wheres, scope, params))
          grouped_base_rows(base_query, filtered, scope, params)
      end

    with {:ok, base_rows} <- base_result do
      final_rows =
        base_rows
        |> augment_with_window_values(windows, [], params, query.time_field)
        |> Enum.map(&finalize_windowed_row(&1, window_select, windows, params))

      {:ok,
       final_rows
       |> sort_rows(query.order_bys, [], params)
       |> maybe_dedupe(query.distinct)
       |> paginate(query.limit, query.offset)}
    end
  end

  defp finalize_windowed_row(row, window_select, windows, params) do
    with_window_values =
      Enum.reduce(window_select, row, fn {:computed, alias_name, expr}, acc ->
        Map.put(acc, alias_name, resolve_rhs(expr, acc, [], params))
      end)

    Map.drop(with_window_values, Enum.map(0..(length(windows) - 1)//1, &window_key/1))
  end

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

  defp predicate_has_aggregate_call?({:in, lhs, values}) when is_list(values),
    do: lhs_has_aggregate_call?(lhs) or Enum.any?(values, &expr_has_aggregate_call?/1)

  defp predicate_has_aggregate_call?({:in, lhs, list_expr}),
    do: lhs_has_aggregate_call?(lhs) or expr_has_aggregate_call?(list_expr)

  defp predicate_has_aggregate_call?({:and, l, r}),
    do: predicate_has_aggregate_call?(l) or predicate_has_aggregate_call?(r)

  defp predicate_has_aggregate_call?({:or, l, r}),
    do: predicate_has_aggregate_call?(l) or predicate_has_aggregate_call?(r)

  defp predicate_has_aggregate_call?({:not, p}), do: predicate_has_aggregate_call?(p)

  # An unresolved `{:variant, ...}` predicate (EP1(e), e.g. `SEARCH`) is
  # opaque to core -- never itself an aggregate-routing trigger. `false`
  # here just means "this predicate isn't why the query would need the
  # grouped path"; if it's genuinely unresolved, `eval_predicate/4` or
  # `eval_group_predicate/5` (whichever path the query actually takes)
  # raises the real, clear error once evaluation actually reaches it --
  # this function only decides routing, not correctness.
  defp predicate_has_aggregate_call?({:variant, _}), do: false

  defp lhs_has_aggregate_call?({:call, name, args}),
    do: name in @aggregate_names or Enum.any?(args, &expr_has_aggregate_call?/1)

  defp lhs_has_aggregate_call?({:dot, base, _path}), do: expr_has_aggregate_call?(base)
  defp lhs_has_aggregate_call?(path) when is_list(path), do: false
  defp lhs_has_aggregate_call?({:literal, _value}), do: false

  defp expr_has_aggregate_call?({:call, name, args}),
    do: name in @aggregate_names or Enum.any?(args, &expr_has_aggregate_call?/1)

  defp expr_has_aggregate_call?({:distinct, expr}), do: expr_has_aggregate_call?(expr)
  defp expr_has_aggregate_call?({:dot, base, _path}), do: expr_has_aggregate_call?(base)

  defp expr_has_aggregate_call?({:arith, _op, l, r}),
    do: expr_has_aggregate_call?(l) or expr_has_aggregate_call?(r)

  defp expr_has_aggregate_call?({:when, clauses, else_expr}) do
    Enum.any?(clauses, fn {predicate, expr} ->
      predicate_has_aggregate_call?(predicate) or expr_has_aggregate_call?(expr)
    end) or expr_has_aggregate_call?(else_expr)
  end

  defp expr_has_aggregate_call?({:window, _call, _partition_by, _order_bys, _frame}), do: false
  defp expr_has_aggregate_call?(_other), do: false

  # ---- Sorting / dedup / pagination ---------------------------------------

  defp sort_rows(rows, [], _scope, _params), do: rows

  defp sort_rows(rows, order_bys, scope, params),
    do: Enum.sort(rows, &sorts_before?(&1, &2, order_bys, scope, params))

  defp sorts_before?(_a, _b, [], _scope, _params), do: true

  defp sorts_before?(a, b, [{key, direction} | rest], scope, params) do
    case term_order(
           resolve_order_key(key, a, scope, params),
           resolve_order_key(key, b, scope, params)
         ) do
      :eq -> sorts_before?(a, b, rest, scope, params)
      :lt -> direction == :asc
      :gt -> direction == :desc
    end
  end

  # An `ORDER BY`/window `order_bys` key is either the original bare
  # field path every caller before this widening already built (`Scry.
  # Core.Query.t()`'s own moduledoc explains why that shape stays valid
  # forever, not just during a migration window) or a full `expr()`
  # (lang_spec.md §8.5's own `ORDER BY relevance() DESC`, `priv/grammar
  # .aether`'s own `order_item` comment) -- resolved via `resolve_rhs/4`
  # like any other expression position. The two are unambiguous: a bare
  # key is always `[String.t(), ...]` (every segment a string), which no
  # tagged `expr()` tuple can ever collide with.
  defp resolve_order_key(path, row, scope, _params) when is_list(path),
    do: get_path(row, scope, path)

  defp resolve_order_key(expr, row, scope, params), do: resolve_rhs(expr, row, scope, params)

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

  # ---- WHERE / WHEN evaluation ---------------------------------------------

  defp matches_all?(row, wheres, scope, params),
    do: Enum.all?(wheres, &eval_predicate(&1, row, scope, params))

  defp eval_predicate({:cmp, op, lhs, nil}, row, scope, params),
    do: compare(op, resolve_predicate_lhs(lhs, row, scope, params), nil)

  defp eval_predicate({:cmp, op, lhs, rhs}, row, scope, params) do
    left = resolve_predicate_lhs(lhs, row, scope, params)

    case resolve_rhs(rhs, row, scope, params) do
      _ when is_nil(left) -> raise_null_safety_error()
      nil -> raise_null_safety_error()
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_predicate({:in, lhs, values}, row, scope, params) when is_list(values) do
    resolve_predicate_lhs(lhs, row, scope, params) in Enum.map(
      values,
      &resolve_rhs(&1, row, scope, params)
    )
  end

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

  defp eval_predicate({:variant, _} = predicate, _row, _scope, _params),
    do: raise_unresolved_variant_predicate(predicate)

  # A kind package's own EP1(e) infix-operator predicate (`Scry.Core.
  # Query`'s own moduledoc has the full shape) reaching a generic
  # predicate evaluator unresolved is a contract violation on that
  # package's own part (`Scry.Core.EngineBehaviour`'s own "what a kind
  # package must guarantee" section) -- a clear, named error, not the
  # `FunctionClauseError` every other unrecognized-shape case here would
  # otherwise raise, since this one specific shape has a real, known
  # cause worth naming (an incomplete lowering pass), not an arbitrary
  # malformed AST.
  defp raise_unresolved_variant_predicate({:variant, detail}) do
    raise ArgumentError,
          "an unresolved {:variant, #{inspect(detail)}} predicate reached generic predicate " <>
            "evaluation -- the kind package that produced it must fully lower every SEARCH-" <>
            "shaped (EP1(e)) predicate leaf, anywhere in wheres/havings, before calling " <>
            "Scry.Core.Executor.run/3,4 (Scry.Core.EngineBehaviour's own moduledoc has the " <>
            "full contract)"
  end

  defp resolve_predicate_lhs({:call, name, _args}, _row, _scope, _params)
       when name in @aggregate_names do
    raise ArgumentError,
          "#{name}(...) is an aggregate function -- only valid inside GROUP BY/HAVING or a " <>
            "flat-aggregate SELECT (lang_spec.md §5.2/§5.8), not an ordinary per-row predicate"
  end

  defp resolve_predicate_lhs({:call, name, args}, row, scope, params) do
    apply_cast(name, Enum.map(args, &resolve_rhs(&1, row, scope, params)))
  end

  defp resolve_predicate_lhs({:dot, base, path}, row, scope, params) do
    get_path_in(resolve_rhs(base, row, scope, params), path)
  end

  defp resolve_predicate_lhs(path, row, scope, _params) when is_list(path),
    do: get_path(row, scope, path)

  defp resolve_predicate_lhs({:literal, value}, _row, _scope, _params), do: value

  defp compare(op, a, b), do: ordering_result(op, term_order(a, b))

  defp raise_null_safety_error do
    raise ArgumentError,
          "comparing a nullable field against a typed value encountered a nil value -- " <>
            "lang_spec.md's own null-safety rule (\"comparing a nullable field directly " <>
            "against a typed value is a hard error\") -- guard it first (e.g. " <>
            "WHERE NOT (field = nil) AND field > ...), or compare against nil explicitly " <>
            "(WHERE field = nil) to check nullness instead"
  end

  defp term_order(%Rational{} = a, b) when is_integer(b) or is_struct(b, Rational) or is_float(b),
    do: Rational.compare(a, b)

  defp term_order(a, %Rational{} = b) when is_integer(a) or is_float(a),
    do: Rational.compare(a, b)

  defp term_order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp term_order(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)

  defp term_order(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  defp ordering_result(:eq, ordering), do: ordering == :eq
  defp ordering_result(:not_eq, ordering), do: ordering != :eq
  defp ordering_result(:lt, ordering), do: ordering == :lt
  defp ordering_result(:gt, ordering), do: ordering == :gt
  defp ordering_result(:le, ordering), do: ordering != :gt
  defp ordering_result(:ge, ordering), do: ordering != :lt

  defp get_path(row, _scope, [_single] = path), do: get_path_in(row, path)

  defp get_path(row, scope, [qualifier | rest] = path) do
    case List.keyfind(scope, qualifier, 0) do
      {^qualifier, scoped_row} -> get_path_in(scoped_row, rest)
      nil -> get_path_in(row, path)
    end
  end

  defp get_path_in(%Row{} = row, [key]), do: Row.fetch!(row, key)
  defp get_path_in(%Row{} = row, [key | rest]), do: row |> Row.fetch!(key) |> get_path_in(rest)

  defp get_path_in(row, [key]), do: Map.get(row, key)
  defp get_path_in(row, [key | rest]), do: row |> Map.get(key, %{}) |> get_path_in(rest)

  defp resolve_rhs({:field, path}, row, scope, _params), do: get_path(row, scope, path)

  defp resolve_rhs({:param, name}, _row, _scope, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing external parameter: #{inspect(name)}"
    end
  end

  defp resolve_rhs({:arith, op, left_expr, right_expr}, row, scope, params) do
    left = resolve_rhs(left_expr, row, scope, params)
    right = resolve_rhs(right_expr, row, scope, params)
    arith(op, left, right)
  end

  defp resolve_rhs({:when, clauses, else_expr}, row, scope, params) do
    case Enum.find(clauses, fn {predicate, _then_expr} ->
           eval_predicate(predicate, row, scope, params)
         end) do
      {_predicate, then_expr} -> resolve_rhs(then_expr, row, scope, params)
      nil -> resolve_rhs(else_expr, row, scope, params)
    end
  end

  defp resolve_rhs({:call, name, _args}, _row, _scope, _params) when name in @aggregate_names do
    raise ArgumentError,
          "#{name}(...) is an aggregate function -- only valid inside GROUP BY/HAVING or a " <>
            "flat-aggregate SELECT (lang_spec.md §5.2/§5.8), not an ordinary per-row expression"
  end

  defp resolve_rhs({:call, name, args}, row, scope, params) do
    apply_cast(name, Enum.map(args, &resolve_rhs(&1, row, scope, params)))
  end

  defp resolve_rhs({:distinct, _expr}, _row, _scope, _params) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not any other call"
  end

  defp resolve_rhs({:dot, base, path}, row, scope, params) do
    get_path_in(resolve_rhs(base, row, scope, params), path)
  end

  defp resolve_rhs(literal, _row, _scope, _params), do: literal

  defp arith(:add, a, b), do: Rational.add(a, b)
  defp arith(:sub, a, b), do: Rational.sub(a, b)
  defp arith(:mul, a, b), do: Rational.mul(a, b)
  defp arith(:div, a, b), do: Rational.div(a, b)
  defp arith(:pow, a, b), do: Rational.pow(a, b)

  # ---- GROUP BY / HAVING / aggregate-function evaluation (eager path) ----

  defp eval_group_predicate({:cmp, op, lhs, nil}, member_rows, scope, params, time_field),
    do: compare(op, resolve_group_lhs(lhs, member_rows, scope, params, time_field), nil)

  defp eval_group_predicate({:cmp, op, lhs, rhs}, member_rows, scope, params, time_field) do
    left = resolve_group_lhs(lhs, member_rows, scope, params, time_field)

    case resolve_group_rhs(rhs, member_rows, scope, params, time_field) do
      _ when is_nil(left) -> raise_null_safety_error()
      nil -> raise_null_safety_error()
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_group_predicate({:in, lhs, values}, member_rows, scope, params, time_field)
       when is_list(values) do
    left = resolve_group_lhs(lhs, member_rows, scope, params, time_field)
    left in Enum.map(values, &resolve_group_rhs(&1, member_rows, scope, params, time_field))
  end

  defp eval_group_predicate({:in, lhs, list_expr}, member_rows, scope, params, time_field) do
    left = resolve_group_lhs(lhs, member_rows, scope, params, time_field)

    case resolve_group_rhs(list_expr, member_rows, scope, params, time_field) do
      list when is_list(list) -> left in list
      other -> raise ArgumentError, "in ... expects a list value, got: #{inspect(other)}"
    end
  end

  defp eval_group_predicate({:and, l, r}, member_rows, scope, params, time_field),
    do:
      eval_group_predicate(l, member_rows, scope, params, time_field) and
        eval_group_predicate(r, member_rows, scope, params, time_field)

  defp eval_group_predicate({:or, l, r}, member_rows, scope, params, time_field),
    do:
      eval_group_predicate(l, member_rows, scope, params, time_field) or
        eval_group_predicate(r, member_rows, scope, params, time_field)

  defp eval_group_predicate({:not, p}, member_rows, scope, params, time_field),
    do: not eval_group_predicate(p, member_rows, scope, params, time_field)

  defp eval_group_predicate(
         {:variant, _} = predicate,
         _member_rows,
         _scope,
         _params,
         _time_field
       ),
       do: raise_unresolved_variant_predicate(predicate)

  defp resolve_group_lhs({:call, name, args}, member_rows, scope, params, time_field) do
    if name in @aggregate_names do
      eval_aggregate(name, args, member_rows, scope, params, time_field)
    else
      apply_cast(
        name,
        Enum.map(args, &resolve_group_rhs(&1, member_rows, scope, params, time_field))
      )
    end
  end

  defp resolve_group_lhs({:dot, base, path}, member_rows, scope, params, time_field) do
    get_path_in(resolve_group_rhs(base, member_rows, scope, params, time_field), path)
  end

  defp resolve_group_lhs(path, member_rows, scope, _params, _time_field) when is_list(path),
    do: get_path(representative(member_rows), scope, path)

  defp resolve_group_lhs({:literal, value}, _member_rows, _scope, _params, _time_field),
    do: value

  defp resolve_group_rhs({:call, name, args}, member_rows, scope, params, time_field) do
    if name in @aggregate_names do
      eval_aggregate(name, args, member_rows, scope, params, time_field)
    else
      apply_cast(
        name,
        Enum.map(args, &resolve_group_rhs(&1, member_rows, scope, params, time_field))
      )
    end
  end

  defp resolve_group_rhs({:field, path}, member_rows, scope, _params, _time_field),
    do: get_path(representative(member_rows), scope, path)

  defp resolve_group_rhs({:param, name}, _member_rows, _scope, params, _time_field) do
    case Map.fetch(params, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing external parameter: #{inspect(name)}"
    end
  end

  defp resolve_group_rhs(
         {:arith, op, left_expr, right_expr},
         member_rows,
         scope,
         params,
         time_field
       ) do
    left = resolve_group_rhs(left_expr, member_rows, scope, params, time_field)
    right = resolve_group_rhs(right_expr, member_rows, scope, params, time_field)
    arith(op, left, right)
  end

  defp resolve_group_rhs({:when, clauses, else_expr}, member_rows, scope, params, time_field) do
    case Enum.find(clauses, fn {predicate, _then_expr} ->
           eval_group_predicate(predicate, member_rows, scope, params, time_field)
         end) do
      {_predicate, then_expr} ->
        resolve_group_rhs(then_expr, member_rows, scope, params, time_field)

      nil ->
        resolve_group_rhs(else_expr, member_rows, scope, params, time_field)
    end
  end

  defp resolve_group_rhs({:distinct, _expr}, _member_rows, _scope, _params, _time_field) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not any other call"
  end

  defp resolve_group_rhs({:dot, base, path}, member_rows, scope, params, time_field) do
    get_path_in(resolve_group_rhs(base, member_rows, scope, params, time_field), path)
  end

  defp resolve_group_rhs(literal, _member_rows, _scope, _params, _time_field), do: literal

  defp representative([]), do: %{}
  defp representative([row | _rest]), do: row

  defp eval_aggregate("count", [{:distinct, arg}], member_rows, scope, params, _time_field) do
    values = Enum.map(member_rows, &resolve_rhs(arg, &1, scope, params))

    if Enum.any?(values, &is_nil/1) do
      raise ArgumentError,
            "aggregate count(distinct ...) encountered a nil value -- lang_spec.md's own " <>
              "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
              "nil-skipping); filter it out explicitly first"
    end

    values |> Enum.uniq() |> length()
  end

  defp eval_aggregate(name, [{:distinct, _arg}], _member_rows, _scope, _params, _time_field) do
    raise ArgumentError, "distinct is only valid inside count(distinct ...), not #{name}(...)"
  end

  defp eval_aggregate(
         "percentile",
         [value_arg, p_arg],
         member_rows,
         scope,
         params,
         _time_field
       ) do
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

  defp eval_aggregate("percentile", args, _member_rows, _scope, _params, _time_field) do
    raise ArgumentError,
          "aggregate percentile/2 expects exactly two arguments (value, p), got #{length(args)}"
  end

  # rate(<duration>) -- lang_spec.md §5.8/§8.2: an events-per-time-unit
  # aggregate (LogQL's own rate() flavor, not PromQL's counter-reset-
  # compensated slope) -- count(rows in scope) normalized to a per-
  # <duration> figure using the group's own min/max value of whatever
  # field the query's own `LAST <duration> OF <field>` clause named
  # (`time_field`, threaded down from `%Scry.Core.Query{}` -- see that
  # module's own moduledoc). `rate`'s own duration argument is
  # deliberately independent of `LAST`'s own duration -- two unrelated
  # numbers, not a default/override pair. Doesn't fit `apply_aggregate/2`
  # 's "reduce a flat already-extracted values list" contract (it needs
  # the raw rows to pull `time_field` from each one, plus `scope`/
  # `params` to resolve its own duration argument), so unlike every
  # other aggregate here it's computed directly, with no
  # `apply_aggregate("rate", ...)` clause at all.
  defp eval_aggregate("rate", [_duration_arg], _member_rows, _scope, _params, nil) do
    raise ArgumentError,
          "rate(...) needs a LAST <duration> OF <field> clause somewhere in this query to " <>
            "know which timestamp field to measure elapsed time against (lang_spec.md §8.2) " <>
            "-- this query has none"
  end

  defp eval_aggregate("rate", [_duration_arg], [], _scope, _params, _time_field), do: nil

  defp eval_aggregate("rate", [duration_arg], member_rows, scope, params, time_field) do
    timestamps = Enum.map(member_rows, &get_path(&1, scope, time_field))

    if Enum.any?(timestamps, &is_nil/1) do
      raise ArgumentError,
            "aggregate rate(...) encountered a nil value in its own LAST ... OF " <>
              "#{inspect(time_field)} timestamp field -- lang_spec.md's own \"Aggregates " <>
              "over nullable fields hard-error the same way\" (no silent nil-skipping); " <>
              "filter it out explicitly first"
    end

    min_ts = Enum.reduce(timestamps, &pick_min/2)
    max_ts = Enum.reduce(timestamps, &pick_max/2)
    elapsed = elapsed_seconds(min_ts, max_ts)

    # A single-row group (min_ts == max_ts): no elapsed interval to
    # measure a density against, both mathematically (division by zero)
    # and physically -- nil, the same "no meaningful value" convention
    # every other aggregate already uses for an empty group, not a
    # crash. Fine-grained GROUP BY usage produces single-row groups
    # constantly in ordinary use; crashing the whole query over one
    # would be far worse than a documented nil.
    if compare(:eq, elapsed, 0) do
      nil
    else
      duration_seconds = resolve_rhs(duration_arg, representative(member_rows), scope, params)
      Rational.div(Rational.mul(length(member_rows), duration_seconds), elapsed)
    end
  end

  defp eval_aggregate(name, [arg], member_rows, scope, params, _time_field) do
    values = Enum.map(member_rows, &resolve_rhs(arg, &1, scope, params))

    if Enum.any?(values, &is_nil/1) do
      raise ArgumentError,
            "aggregate #{name}(...) encountered a nil value -- lang_spec.md's own " <>
              "\"Aggregates over nullable fields hard-error the same way\" (no silent " <>
              "nil-skipping); filter it out explicitly first"
    end

    apply_aggregate(name, values)
  end

  defp eval_aggregate(name, args, _member_rows, _scope, _params, _time_field) do
    raise ArgumentError, "aggregate #{name}/1 expects exactly one argument, got #{length(args)}"
  end

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

  defp pick_min(a, b), do: if(term_order(a, b) == :lt, do: a, else: b)
  defp pick_max(a, b), do: if(term_order(a, b) == :gt, do: a, else: b)

  # rate(...)'s own elapsed-time-span helper -- microsecond precision,
  # matching the finest precision this codebase's own timestamp
  # fixtures already exercise.
  defp elapsed_seconds(%DateTime{} = min_ts, %DateTime{} = max_ts),
    do: Rational.new(DateTime.diff(max_ts, min_ts, :microsecond), 1_000_000)

  defp elapsed_seconds(%NaiveDateTime{} = min_ts, %NaiveDateTime{} = max_ts),
    do: Rational.new(NaiveDateTime.diff(max_ts, min_ts, :microsecond), 1_000_000)

  defp elapsed_seconds(min_ts, max_ts)
       when (is_integer(min_ts) or is_float(min_ts) or is_struct(min_ts, Rational)) and
              (is_integer(max_ts) or is_float(max_ts) or is_struct(max_ts, Rational)) do
    Rational.sub(max_ts, min_ts)
  end

  defp elapsed_seconds(min_ts, max_ts) do
    raise ArgumentError,
          "rate(...)'s own LAST ... OF <field> timestamp field must be a DateTime, " <>
            "NaiveDateTime, or plain numeric value on every row of the group -- got " <>
            "#{inspect(min_ts)}/#{inspect(max_ts)}"
  end

  # ---- Explicit casts ------------------------------------------------------

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

  defp cast_to_exact(n) when is_integer(n), do: n
  defp cast_to_exact(%Rational{} = r), do: r
  defp cast_to_exact(f) when is_float(f), do: Rational.from_float(f)

  defp cast_to_exact(other) do
    raise ArgumentError, "exact(...) does not support this value: #{inspect(other)}"
  end

  defp cast_to_json(s) when is_binary(s) do
    :json.decode(s)
  rescue
    _ -> raise ArgumentError, "json(...) could not parse this value as JSON: #{inspect(s)}"
  end

  defp cast_to_json(other) do
    raise ArgumentError, "json(...) only applies to a String value, got: #{inspect(other)}"
  end

  # ---- Projection -----------------------------------------------------------

  defp project_all(select_items, rows, params) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case project(select_items, row, params) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp project(select_items, row, params) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_item(item, row, params) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :omit -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_item({:field, path}, row, _params),
    do: {:ok, List.last(path), get_path(row, [], path)}

  defp project_item({:computed, alias_name, expr}, row, params),
    do: {:ok, alias_name, resolve_rhs(expr, row, [], params)}

  defp project_item({:field, path, {:param, _} = condition}, row, params) do
    case resolve_rhs(condition, row, [], params) do
      falsy when falsy in [nil, false] -> :omit
      _truthy -> {:ok, List.last(path), get_path(row, [], path)}
    end
  end

  defp project_item({:variant, _} = item, _row, _params),
    do: {:error, {:unsupported_body_item, item}}

  defp project_groups(query, grouped, scope, params) do
    time_field = query.time_field

    Enum.reduce_while(grouped, {:ok, []}, fn {active_fields, member_rows}, {:ok, acc} ->
      if having_matches?(query.havings, member_rows, scope, params, time_field) do
        rolled_up = query.group_bys -- active_fields

        case project_group(query.select, member_rows, rolled_up, scope, params, time_field) do
          {:ok, row} -> {:cont, {:ok, [row | acc]}}
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

  defp having_matches?(havings, member_rows, scope, params, time_field),
    do: Enum.all?(havings, &eval_group_predicate(&1, member_rows, scope, params, time_field))

  defp project_group(select_items, member_rows, rolled_up, scope, params, time_field) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_group_item(item, member_rows, rolled_up, scope, params, time_field) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_group_item({:field, path}, member_rows, rolled_up, scope, _params, _time_field) do
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
         scope,
         params,
         time_field
       ) do
    {:ok, alias_name, resolve_group_rhs(expr, member_rows, scope, params, time_field)}
  end

  defp project_group_item(item, _member_rows, _rolled_up, _scope, _params, _time_field),
    do: {:error, {:unsupported_grouped_body_item, item}}

  # ---- Window functions (lang_spec.md §5.5/§5.8) --------------------------

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

  defp augment_with_window_values(filtered, [], _scope, _params, _time_field), do: filtered

  defp augment_with_window_values(filtered, windows, scope, params, time_field) do
    keyed_value_lists =
      windows
      |> Enum.with_index()
      |> Enum.map(fn {window, index} ->
        {window_key(index), compute_window_values(window, filtered, scope, params, time_field)}
      end)

    filtered
    |> Enum.with_index()
    |> Enum.map(fn {row, row_index} ->
      Enum.reduce(keyed_value_lists, row, fn {key, values}, acc ->
        put_field(acc, key, Enum.at(values, row_index))
      end)
    end)
  end

  defp compute_window_values(
         {:window, {:call, name, args}, partition_by, order_bys, frame},
         filtered_rows,
         scope,
         params,
         time_field
       ) do
    filtered_rows
    |> Enum.with_index()
    |> Enum.group_by(fn {row, _original_index} ->
      Enum.map(partition_by, &get_path(row, scope, &1))
    end)
    |> Enum.flat_map(fn {_partition_key, indexed_rows} ->
      sorted_indexed =
        Enum.sort(indexed_rows, fn {a, _}, {b, _} ->
          sorts_before?(a, b, order_bys, scope, params)
        end)

      sorted_rows = Enum.map(sorted_indexed, &elem(&1, 0))
      n = length(sorted_rows)

      sorted_indexed
      |> Enum.with_index()
      |> Enum.map(fn {{_row, original_index}, pos} ->
        value =
          window_value(
            name,
            args,
            sorted_rows,
            pos,
            n,
            order_bys,
            frame,
            scope,
            params,
            time_field
          )

        {original_index, value}
      end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp window_value(
         "row_number",
         [],
         _sorted_rows,
         pos,
         _n,
         _order_bys,
         _frame,
         _scope,
         _params,
         _time_field
       ),
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
         _params,
         _time_field
       ) do
    raise ArgumentError, "row_number()/0 expects no arguments, got #{length(args)}"
  end

  defp window_value(
         "rank",
         [],
         sorted_rows,
         pos,
         _n,
         order_bys,
         _frame,
         scope,
         params,
         _time_field
       ),
       do: rank_at(sorted_rows, pos, order_bys, scope, params)

  defp window_value(
         "rank",
         args,
         _sorted_rows,
         _pos,
         _n,
         _order_bys,
         _frame,
         _scope,
         _params,
         _time_field
       ) do
    raise ArgumentError, "rank()/0 expects no arguments, got #{length(args)}"
  end

  defp window_value(
         "first_value",
         [arg],
         sorted_rows,
         pos,
         n,
         _order_bys,
         frame,
         scope,
         params,
         _time_field
       ) do
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
         _params,
         _time_field
       ) do
    raise ArgumentError, "first_value/1 expects exactly one argument, got #{length(args)}"
  end

  defp window_value(
         "last_value",
         [arg],
         sorted_rows,
         pos,
         n,
         _order_bys,
         frame,
         scope,
         params,
         _time_field
       ) do
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
         _params,
         _time_field
       ) do
    raise ArgumentError, "last_value/1 expects exactly one argument, got #{length(args)}"
  end

  defp window_value(name, args, sorted_rows, pos, n, _order_bys, frame, scope, params, time_field)
       when name in @aggregate_names do
    {lo, hi} = frame_range(frame, pos, n)
    frame_rows = slice_frame(sorted_rows, lo, hi)
    eval_aggregate(name, args, frame_rows, scope, params, time_field)
  end

  defp window_value(
         name,
         _args,
         _sorted_rows,
         _pos,
         _n,
         _order_bys,
         _frame,
         _scope,
         _params,
         _time_field
       ) do
    raise ArgumentError, "#{name}(...) is not a valid window function"
  end

  defp frame_range(nil, _pos, n), do: {0, n - 1}

  defp frame_range({start_bound, end_bound}, pos, n),
    do: {resolve_bound(start_bound, pos, n), resolve_bound(end_bound, pos, n)}

  defp resolve_bound(:unbounded_preceding, _pos, _n), do: 0
  defp resolve_bound({:preceding, k}, pos, _n), do: max(0, pos - k)
  defp resolve_bound(:current_row, pos, _n), do: pos
  defp resolve_bound({:following, k}, pos, n), do: min(n - 1, pos + k)
  defp resolve_bound(:unbounded_following, _pos, n), do: n - 1

  defp slice_frame(_rows, lo, hi) when lo > hi, do: []
  defp slice_frame(rows, lo, hi), do: Enum.slice(rows, lo..hi)

  defp rank_at(sorted_rows, pos, order_bys, scope, params),
    do: pos + 1 - count_ties_before(sorted_rows, pos, order_bys, scope, params)

  defp count_ties_before(_sorted_rows, 0, _order_bys, _scope, _params), do: 0

  defp count_ties_before(sorted_rows, pos, order_bys, scope, params) do
    if ties?(Enum.at(sorted_rows, pos - 1), Enum.at(sorted_rows, pos), order_bys, scope, params) do
      1 + count_ties_before(sorted_rows, pos - 1, order_bys, scope, params)
    else
      0
    end
  end

  defp ties?(a, b, order_bys, scope, params) do
    Enum.all?(order_bys, fn {key, _direction} ->
      term_order(
        resolve_order_key(key, a, scope, params),
        resolve_order_key(key, b, scope, params)
      ) ==
        :eq
    end)
  end
end
