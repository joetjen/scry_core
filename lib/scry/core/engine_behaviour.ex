defmodule Scry.Core.EngineBehaviour do
  @moduledoc """
  The shared execution scaffold every kind's own engine behaviour is
  meant to build on top of (impl_spec.md §2: "core exposes the shared
  execution scaffold every kind's own behaviour builds on top of").
  Covers only what filtering and projecting a `%Scry.Core.Query{}`
  actually needs from an adapter -- fetching a source's rows.
  Everything else (`where`/`select` evaluation) is core's own job,
  `Scry.Core.Executor`, not an adapter's, so it's not part of this
  contract at all.

  A kind-specific behaviour (`scry_time_series`'s own, once it exists)
  is expected to extend this shape with callbacks for whatever
  EP1/EP2 constructs that kind's own grammar fragment contributes --
  nothing here assumes an adapter only ever implements the one
  callback below.

  `fetch/2` takes just a source path, not the query's `wheres` -- so an
  adapter that only implements it fetches every row for a source and
  lets `Scry.Core.Executor` filter client-side. Always correct, not
  necessarily efficient.

  `fetch/2` returns any `Enumerable.t()`, not just a plain list -- a
  real adapter backed by a genuine streaming cursor (a Postgrex
  cursor, an ETS/Mnesia match continuation, ...) can return something
  lazy instead of pulling every row into memory up front. A plain
  list already satisfies `Enumerable.t()`, so every existing
  implementation of this callback needs no code changes at all;
  `Scry.Core.Cursor` is the intended way to consume whatever comes
  back one row (or one batch) at a time, for anything that wants to
  avoid forcing the whole thing into memory.

  **`fetch/3` (optional) -- real pushdown, on top of this same
  contract, not a different one.** Receives the whole `%Scry.Core.
  Query{}` too, so an adapter backed by a real query language of its
  own (SQL, an ETS match spec, ...) can translate whatever it
  recognizes -- typically some or all of `query.wheres` -- into a
  native, more efficient fetch, instead of always returning every row
  for `source` unfiltered. `Scry.Core.Executor` prefers `fetch/3` when
  a module implements it (`function_exported?/3`), falling back to
  `fetch/2` otherwise -- every engine that only implements `fetch/2`
  keeps working completely unchanged; this is a strictly additive,
  opt-in capability, never a breaking change to the existing contract.

  **The load-bearing safety invariant, and it's asymmetric**:
  `Scry.Core.Executor` makes zero assumptions about how much (or how
  correctly) a `fetch/3` implementation actually optimized -- it
  unconditionally re-applies its entire existing pipeline (`wheres`,
  grouping/aggregation, sorting, dedup, pagination, projection) to
  whatever comes back, exactly as it already does for `fetch/2`. An
  engine that *over-includes* (returns extra rows a correct pushdown
  would have excluded, or ignores `query` entirely and behaves exactly
  like `fetch/2`) is always corrected downstream -- filtering an
  already-filtered set is idempotent. An engine that *under-includes*
  -- a buggy predicate translation that wrongly drops a row a correct
  fetch would have returned -- is **not** caught by anything, because
  `Executor` never sees the dropped row to compare against. `fetch/3`
  is a trust-the-engine-for-completeness,
  verify-the-engine-for-correctness-of-what-it-returns contract, not a
  fully-checked one.

  **Scope boundary**: `fetch/3` may narrow *which* rows come back and
  in *what order*, but must still return the same row shape `fetch/2`
  would for that source -- never pre-aggregated or restructured data.
  Translating `GROUP BY`/aggregates into a native aggregation would
  require `Executor` to trust an engine's own aggregation logic
  outright, breaking the invariant above -- a real, separate, harder
  problem, not attempted here. Predicates referencing `{:param, name}`
  (a `$name`-bound value) also aren't pushed down through `fetch/3` --
  only literal-vs-field comparisons are real candidates for
  translation there. Aggregation pushdown remains a genuinely separate
  mechanism, not attempted here.

  **`fetch/4` (optional) -- `fetch/3` plus a hints map, for an engine
  that wants to do more than translate `wheres`.** `Scry.Core.Executor`
  prefers `fetch/4` over `fetch/3` over `fetch/2`, in that order, via
  `function_exported?/3` -- every engine that doesn't implement it is
  completely unaffected, same additive/opt-in posture as `fetch/3`
  itself. `opts` is a plain, open map (not a fixed-arity parameter list)
  specifically so it can grow new keys later without another signature
  change -- this version populates exactly one: `opts.columns ::
  {:ok, MapSet.t(String.t())} | :unknown`, the exact top-level columns
  of `source` this query references anywhere (`wheres`/`havings`/
  `group_bys`/`order_bys`/`select`), computed by `Executor` itself
  (`Scry.Core.Executor.referenced_top_level_fields/2`) so the one
  AST-analysis implementation can never drift out of sync with
  `get_path/3`'s own qualifier-resolution semantics. `:unknown` means
  exactly what it did before this callback existed: an engine that
  sees it should fetch every column, unconditionally -- the same
  "always correct, not necessarily efficient" posture `fetch/2` itself
  has. A future increment may add `opts.params` for the `{:param,
  name}`-pushdown extension point mentioned above; `opts` being an open
  map is what keeps that non-breaking too.
  """

  @typedoc "A single result row -- either a plain string-keyed map, matching `Scry.Core.Query`'s own path segments, or a `Scry.Core.Row.t()` (only ever produced by an engine opting into `fetch/4`'s compact-row representation)."
  @type row :: %{optional(String.t()) => term()} | Scry.Core.Row.t()

  @typedoc "Optional per-fetch hints, computed by `Scry.Core.Executor` itself and passed to `fetch/4`. Open map, may grow new keys in a future, non-breaking increment."
  @type fetch_opts :: %{optional(:columns) => {:ok, MapSet.t(String.t())} | :unknown}

  @doc "Fetches every row for `source` (a dotted path, e.g. `[\"orders\"]`) from `conn` -- any `Enumerable.t()` of `row()`, not necessarily a materialized list (`Scry.Core.Cursor`'s own moduledoc has the full reasoning)."
  @callback fetch(conn :: term(), source :: [String.t()]) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks fetch: 3, fetch: 4

  @doc """
  Like `fetch/2`, but also receives the whole query, so an adapter can
  optionally push some or all of it down to its own backend before
  `Scry.Core.Executor` re-applies the query's full semantics regardless
  (this module's own moduledoc has the complete safety-invariant
  reasoning). Optional -- an engine that doesn't implement this falls
  back to `fetch/2`, unchanged.
  """
  @callback fetch(conn :: term(), source :: [String.t()], query :: Scry.Core.Query.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Like `fetch/3`, but also receives `opts` (this module's own moduledoc
  has the full `fetch/4` reasoning). Optional -- an engine that doesn't
  implement this falls back to `fetch/3`, then `fetch/2`, unchanged.
  """
  @callback fetch(
              conn :: term(),
              source :: [String.t()],
              query :: Scry.Core.Query.t(),
              opts :: fetch_opts()
            ) :: {:ok, Enumerable.t()} | {:error, term()}
end
