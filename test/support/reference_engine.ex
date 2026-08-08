defmodule Scry.Core.Test.ReferenceEngine do
  @moduledoc """
  A minimal, generic `Scry.Core.EngineBehaviour` implementation for
  tests that don't care about a real backend's own native pushdown --
  `conn` is just a `%{source_path => rows}` map, and this delegates
  everything (`WITH`/nested-`SELECT`/combinators via `Scry.Core.
  QueryOps.run_document/4`, a flat query's own `WHERE`/`GROUP BY`/
  sorting/projection via `Scry.Core.QueryOps.run_flat/3`) straight to
  the shared toolkit -- proving the toolkit itself is correct,
  independent of any one engine's own translation choices. Not the
  real static engine (that's `scry_engine_inmemory`, a separate
  package `scry_core` can't depend on without a cycle).
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps}

  @impl true
  def execute(data, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(data, combined, params, __MODULE__)

  def execute(data, %Query{} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or
         (match?([_], query.source) and Map.has_key?(query.with_bindings, hd(query.source))) do
      QueryOps.run_document(data, query, params, __MODULE__)
    else
      case Map.fetch(data, query.source) do
        {:ok, rows} -> QueryOps.run_flat(rows, query, params)
        :error -> {:error, {:query_error, {:no_such_source, query.source}}}
      end
    end
  end
end

defmodule Scry.Core.Test.RowReferenceEngine do
  @moduledoc """
  Same behaviour as `Scry.Core.Test.ReferenceEngine`, but a flat leaf's
  own rows come back as `Scry.Core.Row.t()` values instead of plain
  maps -- simulates a real columnar engine (`Scry.Engine.Exqlite`, for
  its own directly-compiled-SQL path) that fully computes a flat query
  itself and returns `Row` structs straight from `execute/3`, no
  `Scry.Core.QueryOps.run_flat/3`/projection pass involved.

  Proves `Scry.Core.QueryOps.run_document/4`'s own correlation (`{:field,
  [ancestor, field]}` rewriting, nested-`SELECT` result augmentation),
  window-function synthetic-column augmentation, and `CombinedQuery`
  set-combinator machinery all handle a `Row`-returning engine
  correctly -- none of those call sites may assume a row is a plain
  map, and a naive `Map.put`/`Map.get` anywhere in that path would
  either silently corrupt a `Row` (structs are technically maps at the
  BEAM level, so `Map.put/3` "succeeds" while producing garbage) or
  silently return `nil` (`Map.get/2` on a struct with no such literal
  key) instead of raising -- confirmed fixed by this suite, not
  assumed.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps, Row}

  @impl true
  def execute(data, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(data, combined, params, __MODULE__)

  def execute(data, %Query{} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or
         (match?([_], query.source) and Map.has_key?(query.with_bindings, hd(query.source))) do
      QueryOps.run_document(data, query, params, __MODULE__)
    else
      case Map.fetch(data, query.source) do
        {:ok, rows} ->
          with {:ok, plain_rows} <- QueryOps.run_flat(rows, query, params) do
            {:ok, Enum.map(plain_rows, &to_row/1)}
          end

        :error ->
          {:error, {:query_error, {:no_such_source, query.source}}}
      end
    end
  end

  defp to_row(%{} = map) do
    columns = Map.keys(map)
    index = Row.build_index(columns)
    Row.new(index, Enum.map(columns, &Map.fetch!(map, &1)))
  end
end

defmodule Scry.Core.Test.StreamingReferenceEngine do
  @moduledoc """
  Same behaviour as `Scry.Core.Test.ReferenceEngine`, but a flat
  leaf's own rows come back as a genuine `Stream` instead of a plain
  list -- proves `Scry.Core.EngineBehaviour.execute/3`'s own widened
  contract (any `Enumerable.t()`, not just a list) actually works end
  to end through `Scry.Core.Executor.run/4`, not just that the type
  signature got wider.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, Query, QueryOps}

  @impl true
  def execute(data, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(data, combined, params, __MODULE__)

  def execute(data, %Query{} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or
         (match?([_], query.source) and Map.has_key?(query.with_bindings, hd(query.source))) do
      QueryOps.run_document(data, query, params, __MODULE__)
    else
      case Map.fetch(data, query.source) do
        {:ok, rows} -> QueryOps.run_flat(Stream.map(rows, & &1), query, params)
        :error -> {:error, {:query_error, {:no_such_source, query.source}}}
      end
    end
  end
end
