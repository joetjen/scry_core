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

  A nested `SELECT` body item is **not correlated** to its enclosing
  row -- Phase 1's grammar (`priv/grammar.aether`) has no syntax for a
  nested predicate to reference an outer row's fields at all yet, so
  every outer row gets the identical nested result. A real, honest
  limitation of what the grammar can express today, not something this
  module works around.

  **`run/3` still only ignores `group_by`/`having`.** Those two need
  real aggregate-*expression* evaluation, which doesn't exist anywhere
  in this codebase yet, grammar included -- there's no syntax to even
  write `sum(total)` as a body item today, so there's nothing yet to
  execute even if this module tried. `distinct`/`order_bys`/`limit`/
  `offset` are now applied, in the pipeline lang_spec.md §6's own
  "Modifier ordering" paragraph describes: filter, sort (`order_bys`,
  evaluated against each *source* row, before projection -- see
  `sort_rows/2`'s own comment for why), project, dedupe (`distinct`,
  the block's *projected* output shape per §6's "Deduplication
  semantics", preserving first-occurrence order), then paginate
  (`limit`/`offset`). lang_spec.md §5.2's own "ordering by a field
  outside the projected shape while distinct is active is a
  compile-time error" is **not** enforced here -- no static/compile-time
  validation pass exists anywhere in this codebase yet (the same gap
  `having`'s own aggregate-expression requirement has); this module
  still produces a well-defined, deterministic result for that case
  (sorted, pre-dedup order breaks the tie for which duplicate's
  position "wins"), it just doesn't reject it the way a real compiler
  eventually should.
  """

  alias ScryCore.{EngineBehaviour, Query, Rational}

  @doc """
  Executes `query` against `engine_module` (a module implementing
  `ScryCore.EngineBehaviour`) using `conn`. Returns one projected
  result row per source row surviving every predicate in `query.wheres`
  (combined with `and`), sorted, deduped, and paginated per
  `query.order_bys`/`query.distinct`/`query.limit`/`query.offset` --
  see this module's own moduledoc for the exact pipeline order and what
  it still doesn't do (`group_by`/`having`).
  """
  @spec run(Query.t(), module(), term()) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  def run(%Query{} = query, engine_module, conn) do
    with {:ok, rows} <- engine_module.fetch(conn, query.source) do
      sorted =
        rows
        |> Enum.filter(&matches_all?(&1, query.wheres))
        |> sort_rows(query.order_bys)

      with {:ok, projected} <- project_all(sorted, query.select, engine_module, conn) do
        {:ok,
         projected
         |> maybe_dedupe(query.distinct)
         |> paginate(query.limit, query.offset)}
      end
    end
  end

  # Sorts *source* rows (`get_path/2` against the same row shape `where`
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
  defp sort_rows(rows, []), do: rows
  defp sort_rows(rows, order_bys), do: Enum.sort(rows, &sorts_before?(&1, &2, order_bys))

  defp sorts_before?(_a, _b, []), do: true

  defp sorts_before?(a, b, [{path, direction} | rest]) do
    case term_order(get_path(a, path), get_path(b, path)) do
      :eq -> sorts_before?(a, b, rest)
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

  defp matches_all?(row, wheres), do: Enum.all?(wheres, &eval_predicate(&1, row))

  # `rhs` resolves first (either the literal value as-is, or -- new,
  # lang_spec.md §5.9 -- another field's value via `{:field, path}`,
  # the same tag `Query.body_item/0` uses for a projected field),
  # *then* dispatches on what it resolved to. Collapsing what used to
  # be two separate clauses (one `:match`-only, one everything-else)
  # into one resolve-then-dispatch shape closes a real gap the old
  # split would otherwise have reopened for `{:field, ...}`: `WHERE
  # name ~ some_field` where `some_field` resolves to a non-regex would
  # have hit the generic `compare/3` clause -> `ordering_result(:match,
  # _)`, an undocumented `FunctionClauseError`, instead of the same
  # (deliberate, documented) crash `Regex.match?/2` itself already
  # gives for a non-string *left*-hand value. No defensive
  # `is_binary/1`/`is_struct/2` guard here either -- the same "not
  # specially hardened against a type mismatch" posture every other
  # predicate in this module already has (e.g. `<`/`>` against
  # mismatched types already "works" via Erlang's own total term order
  # without erroring, just not usefully).
  defp eval_predicate({:cmp, op, path, rhs}, row) do
    left = get_path(row, path)

    case resolve_rhs(rhs, row) do
      %Regex{} = regex when op == :match -> Regex.match?(regex, left)
      right -> compare(op, left, right)
    end
  end

  defp eval_predicate({:in, path, values}, row), do: get_path(row, path) in values
  defp eval_predicate({:and, l, r}, row), do: eval_predicate(l, row) and eval_predicate(r, row)
  defp eval_predicate({:or, l, r}, row), do: eval_predicate(l, row) or eval_predicate(r, row)
  defp eval_predicate({:not, p}, row), do: not eval_predicate(p, row)

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
  # used by `sorts_before?/3` for any value type that doesn't need one
  # of the special cases above.
  defp term_order(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  # Shared by `compare/2` above and `sorts_before?/3` -- both ultimately
  # just need to turn a `term_order/2` result into what they
  # respectively want (a boolean for a given comparison operator; a
  # three-way branch for a sort comparator).
  defp ordering_result(:eq, ordering), do: ordering == :eq
  defp ordering_result(:not_eq, ordering), do: ordering != :eq
  defp ordering_result(:lt, ordering), do: ordering == :lt
  defp ordering_result(:gt, ordering), do: ordering == :gt
  defp ordering_result(:le, ordering), do: ordering != :gt
  defp ordering_result(:ge, ordering), do: ordering != :lt

  defp get_path(row, [key]), do: Map.get(row, key)
  defp get_path(row, [key | rest]), do: row |> Map.get(key, %{}) |> get_path(rest)

  defp resolve_rhs({:field, path}, row), do: get_path(row, path)
  defp resolve_rhs(literal, _row), do: literal

  defp project_all(rows, select_items, engine_module, conn) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case project(row, select_items, engine_module, conn) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp project(row, select_items, engine_module, conn) do
    Enum.reduce_while(select_items, {:ok, %{}}, fn item, {:ok, acc} ->
      case project_item(item, row, engine_module, conn) do
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp project_item({:field, path}, row, _engine_module, _conn) do
    {:ok, List.last(path), get_path(row, path)}
  end

  defp project_item(%Query{source: source} = nested, _row, engine_module, conn) do
    case run(nested, engine_module, conn) do
      {:ok, nested_rows} -> {:ok, List.last(source), nested_rows}
      {:error, _} = err -> err
    end
  end

  defp project_item({:variant, _} = item, _row, _engine_module, _conn) do
    {:error, {:unsupported_body_item, item}}
  end
end
