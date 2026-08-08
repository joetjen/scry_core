defmodule Scry.Core.Executor do
  @moduledoc """
  The top-level entry point for running a parsed `%Scry.Core.Query{}`
  or `%Scry.Core.CombinedQuery{}` against a module implementing
  `Scry.Core.EngineBehaviour`. `run/3,4` itself does almost nothing --
  the engine's own `execute/3` is authoritative for the *entire*
  query, `WITH` bindings, nested/correlated `SELECT`, and combinators
  (`UNION`/`INTERSECT`/`EXCEPT`) included, not just a flat `WHERE`+
  projection slice of it. Nothing here re-applies, re-verifies, or
  falls back to a different implementation of anything an engine
  returns.

  This is a deliberate design choice, not an oversight: a real,
  correlation-aware nested `SELECT` maps naturally onto a native SQL
  `JOIN` (or a `WITH`-bound name onto a native CTE), and a query
  compiler sophisticated enough to do that translation should be free
  to receive the *whole* document and produce one native query for
  it, rather than have `scry_core` pre-decompose it into pieces first.
  An engine without that sophistication (or one that hasn't
  implemented every construct yet) can instead delegate some or all
  of a query to `Scry.Core.QueryOps.run_document/4` or `Scry.Core.
  QueryOps.run_flat/3` from inside its own `execute/3` -- entirely its
  own choice, never something this module does automatically on an
  engine's behalf.

  A body item tagged `:variant` (`Scry.Core.Query.body_item/0`) has no
  execution semantics defined by `scry_core` at all -- a kind-specific
  executor (`scry_time_series`'s own, for instance) is expected to
  fully lower its own EP1/EP2 constructs into ordinary core AST before
  ever calling `run/3,4`, exactly as `Scry.Core.EngineBehaviour`'s own
  moduledoc documents.
  """

  alias Scry.Core.{CombinedQuery, Cursor, Query}

  @typedoc "External values bound to a query's own `$name` placeholders, by name."
  @type params :: %{optional(String.t()) => term()}

  @doc """
  Runs `query_or_combined` against `engine_module` (a module
  implementing `Scry.Core.EngineBehaviour`) using `conn`, resolving
  any `$name` placeholder against `params`. Delegates the entire
  query -- `WITH` bindings, nested/correlated `SELECT`, combinators,
  `GROUP BY`/`HAVING`/aggregates, `ORDER BY`/`DISTINCT`/`LIMIT`/
  `OFFSET`, projection -- to `engine_module.execute/3`; this function
  only wraps the successful result in a `Scry.Core.Cursor.t()` for lazy
  consumption (`Cursor.next/1`/`take/2`/`skip/1,2`/`to_list/1`).

  Returns `{:error, reason}` when `engine_module.execute/3` declines
  or fails (`Scry.Core.EngineBehaviour.error/0`) -- passed through
  unchanged, this module makes no attempt to retry or interpret it
  differently. A failure an engine can only discover mid-enumeration
  (a genuinely lazy `Enumerable.t()` result) surfaces as whatever
  exception the engine itself raises when a caller pulls far enough to
  reach it, not as an `{:error, _}` return from this function.
  """
  @spec run(Query.t() | CombinedQuery.t(), module(), term(), params()) ::
          {:ok, Cursor.t()} | {:error, term()}
  def run(query_or_combined, engine_module, conn, params \\ %{}) do
    with {:ok, rows} <- engine_module.execute(conn, query_or_combined, params) do
      {:ok, Cursor.new(rows)}
    end
  end
end
