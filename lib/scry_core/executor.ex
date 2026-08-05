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

  **`run/3` only ever applies `where`/`select`.** `%Query{}` can now
  carry `group_bys`/`havings`/`distinct`/`order_bys`/`limit`/`offset`
  too (the grammar produces them, `ScryCore.Actions`), but this module
  silently ignores all of them for now -- a real gap, not an oversight.
  `distinct`/`order_by`/`limit`/`offset` are conceptually
  straightforward as a post-projection pass; `group_by`/`having` are
  not (they need real aggregate-*expression* evaluation, which doesn't
  exist anywhere in this codebase yet, grammar included -- there's no
  syntax to even write `sum(total)` as a body item today). Left as a
  deliberately separate, later increment rather than rushed in here,
  since how `distinct`/`order_by` compose exactly (whether `order_by`
  sorts pre- or post-projection data, in particular) is a genuine
  design question lang_spec.md §5.2/§6 states from a user's perspective
  ("what's allowed to reference what"), not as an implementer-ready
  algorithm.
  """

  alias ScryCore.{EngineBehaviour, Query, Rational}

  @doc """
  Executes `query` against `engine_module` (a module implementing
  `ScryCore.EngineBehaviour`) using `conn`. Returns one projected
  result row per source row surviving every predicate in `query.wheres`
  (combined with `and`).
  """
  @spec run(Query.t(), module(), term()) ::
          {:ok, [EngineBehaviour.row()]} | {:error, term()}
  def run(%Query{} = query, engine_module, conn) do
    with {:ok, rows} <- engine_module.fetch(conn, query.source) do
      rows
      |> Enum.filter(&matches_all?(&1, query.wheres))
      |> project_all(query.select, engine_module, conn)
    end
  end

  defp matches_all?(row, wheres), do: Enum.all?(wheres, &eval_predicate(&1, row))

  defp eval_predicate({:cmp, op, path, literal}, row),
    do: compare(op, get_path(row, path), literal)

  defp eval_predicate({:in, path, values}, row), do: get_path(row, path) in values
  defp eval_predicate({:and, l, r}, row), do: eval_predicate(l, row) and eval_predicate(r, row)
  defp eval_predicate({:or, l, r}, row), do: eval_predicate(l, row) or eval_predicate(r, row)
  defp eval_predicate({:not, p}, row), do: not eval_predicate(p, row)

  # `%Rational{}`/integer are compared exactly (cross-multiplication via
  # Rational.compare/2, ScryCore.Rational's own moduledoc) rather than
  # through Kernel's `< > <= >=`, which order structs by their raw field
  # values -- structurally consistent, but not numerically meaningful
  # for two arbitrary rationals (e.g. comparing 1/2 against 2/3 by field
  # order is not the same as comparing their magnitudes). A row's own
  # field value is plain data straight from an engine's `fetch/2`, so it
  # only ever needs this treatment when it's already an integer -- a
  # native float there isn't yet covered (lang_spec.md §4's "conversion
  # on ingest" model has no adapter-facing hook yet, a real, separate
  # gap, not something this clause papers over).
  defp compare(op, %Rational{} = a, b) when is_integer(b) or is_struct(b, Rational),
    do: ordering_result(op, Rational.compare(a, b))

  defp compare(op, a, %Rational{} = b) when is_integer(a),
    do: ordering_result(op, Rational.compare(a, b))

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
  defp compare(op, %DateTime{} = a, %DateTime{} = b),
    do: ordering_result(op, DateTime.compare(a, b))

  defp compare(op, %NaiveDateTime{} = a, %NaiveDateTime{} = b),
    do: ordering_result(op, NaiveDateTime.compare(a, b))

  defp compare(:eq, a, b), do: a == b
  defp compare(:not_eq, a, b), do: a != b
  defp compare(:lt, a, b), do: a < b
  defp compare(:gt, a, b), do: a > b
  defp compare(:le, a, b), do: a <= b
  defp compare(:ge, a, b), do: a >= b

  # Shared by every `:lt`/`:eq`/`:gt`-returning `compare/2` above
  # (`Rational`, `DateTime`, `NaiveDateTime`).
  defp ordering_result(:eq, ordering), do: ordering == :eq
  defp ordering_result(:not_eq, ordering), do: ordering != :eq
  defp ordering_result(:lt, ordering), do: ordering == :lt
  defp ordering_result(:gt, ordering), do: ordering == :gt
  defp ordering_result(:le, ordering), do: ordering != :gt
  defp ordering_result(:ge, ordering), do: ordering != :lt

  defp get_path(row, [key]), do: Map.get(row, key)
  defp get_path(row, [key | rest]), do: row |> Map.get(key, %{}) |> get_path(rest)

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
