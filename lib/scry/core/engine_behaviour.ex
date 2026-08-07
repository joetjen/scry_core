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
  (a `$name`-bound value) also aren't pushed down -- `params` isn't
  threaded into `fetch/3` in this version of the contract -- only
  literal-vs-field comparisons are real candidates for translation.
  Both are natural, non-breaking future extensions (a `fetch/4` adding
  `params`; aggregation pushdown as a genuinely separate mechanism),
  not gaps this contract silently papers over.
  """

  @typedoc "A single result row -- string keys, matching `Scry.Core.Query`'s own path segments."
  @type row :: %{optional(String.t()) => term()}

  @doc "Fetches every row for `source` (a dotted path, e.g. `[\"orders\"]`) from `conn` -- any `Enumerable.t()` of `row()`, not necessarily a materialized list (`Scry.Core.Cursor`'s own moduledoc has the full reasoning)."
  @callback fetch(conn :: term(), source :: [String.t()]) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks fetch: 3

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
end
