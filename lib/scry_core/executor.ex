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

  **`run/3` still only ignores `group_by`/`having`.** Those two need
  real aggregate-*expression* evaluation, which doesn't exist anywhere
  in this codebase yet, grammar included -- there's no syntax to even
  write `sum(total)` as a body item today, so there's nothing yet to
  execute even if this module tried. `distinct`/`order_bys`/`limit`/
  `offset` are applied in the pipeline lang_spec.md §6's own "Modifier
  ordering" paragraph describes: filter, sort (`order_bys`, evaluated
  against each *source* row, before projection -- see `sort_rows/3`'s
  own comment for why), project, dedupe (`distinct`, the block's
  *projected* output shape per §6's "Deduplication semantics",
  preserving first-occurrence order), then paginate (`limit`/`offset`).
  lang_spec.md §5.2's own "ordering by a field outside the projected
  shape while distinct is active is a compile-time error" is **not**
  enforced here -- no static/compile-time validation pass exists
  anywhere in this codebase yet (the same gap `having`'s own
  aggregate-expression requirement has); this module still produces a
  well-defined, deterministic result for that case (sorted, pre-dedup
  order breaks the tie for which duplicate's position "wins"), it just
  doesn't reject it the way a real compiler eventually should.

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
  `query.distinct`/`query.limit`/`query.offset` -- see this module's
  own moduledoc for the exact pipeline order, the correlation/
  `REQUIRED`/external-parameter semantics, and what it still doesn't
  do (`group_by`/`having`).
  """
  @spec run(Query.t(), module(), term(), params()) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  def run(%Query{} = query, engine_module, conn, params \\ %{}),
    do: run(query, [], params, engine_module, conn)

  @spec run(Query.t(), scope(), params(), module(), term()) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  defp run(%Query{} = query, scope, params, engine_module, conn) do
    with {:ok, rows} <- engine_module.fetch(conn, query.source) do
      sorted =
        rows
        |> Enum.filter(&matches_all?(&1, query.wheres, scope, params))
        |> sort_rows(query.order_bys, scope)

      own_name = List.last(query.source)

      with {:ok, projected} <-
             project_all(sorted, query.select, own_name, scope, params, engine_module, conn) do
        {:ok,
         projected
         |> maybe_dedupe(query.distinct)
         |> paginate(query.limit, query.offset)}
      end
    end
  end

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
  defp eval_predicate({:cmp, op, path, rhs}, row, scope, params) do
    left = get_path(row, scope, path)

    case resolve_rhs(rhs, row, scope, params) do
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  # Each element resolved the same way a comparison's own right-hand
  # side is -- `in [$a, $b]`/`in [orders.status]` work for exactly the
  # same reason `= $a`/`= orders.status` do, not a separate mechanism.
  defp eval_predicate({:in, path, values}, row, scope, params) do
    get_path(row, scope, path) in Enum.map(values, &resolve_rhs(&1, row, scope, params))
  end

  defp eval_predicate({:and, l, r}, row, scope, params),
    do: eval_predicate(l, row, scope, params) and eval_predicate(r, row, scope, params)

  defp eval_predicate({:or, l, r}, row, scope, params),
    do: eval_predicate(l, row, scope, params) or eval_predicate(r, row, scope, params)

  defp eval_predicate({:not, p}, row, scope, params),
    do: not eval_predicate(p, row, scope, params)

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

  defp resolve_rhs(literal, _row, _scope, _params), do: literal

  defp project_all(rows, select_items, own_name, scope, params, engine_module, conn) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case project(row, select_items, own_name, scope, params, engine_module, conn) do
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
  # `INNER JOIN`s needs every one of them to match.
  defp project(row, select_items, own_name, scope, params, engine_module, conn) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_item(item, row, own_name, scope, params, engine_module, conn) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :skip -> {:halt, :skip}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_item({:field, path}, row, _own_name, scope, _params, _engine_module, _conn) do
    {:ok, List.last(path), get_path(row, scope, path)}
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
         engine_module,
         conn
       ) do
    case run(nested, [{own_name, row} | scope], params, engine_module, conn) do
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
         _engine_module,
         _conn
       ) do
    {:error, {:unsupported_body_item, item}}
  end
end
