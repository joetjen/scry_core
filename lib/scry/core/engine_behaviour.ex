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

  No pushdown support yet -- `fetch/2` takes just a source path, not
  the query's `wheres`, so every adapter (including a real one) fetches
  every row for a source and lets `Scry.Core.Executor` filter
  client-side. Always correct, not necessarily efficient; a real
  adapter wanting to push predicates down to its own store is a later
  optimization on top of this same contract, not a different one.

  `fetch/2` returns any `Enumerable.t()`, not just a plain list -- a
  real adapter backed by a genuine streaming cursor (a Postgrex
  cursor, an ETS/Mnesia match continuation, ...) can return something
  lazy instead of pulling every row into memory up front. A plain
  list already satisfies `Enumerable.t()`, so every existing
  implementation of this callback needs no code changes at all;
  `Scry.Core.Cursor` is the intended way to consume whatever comes
  back one row (or one batch) at a time, for anything that wants to
  avoid forcing the whole thing into memory.
  """

  @typedoc "A single result row -- string keys, matching `Scry.Core.Query`'s own path segments."
  @type row :: %{optional(String.t()) => term()}

  @doc "Fetches every row for `source` (a dotted path, e.g. `[\"orders\"]`) from `conn` -- any `Enumerable.t()` of `row()`, not necessarily a materialized list (`Scry.Core.Cursor`'s own moduledoc has the full reasoning)."
  @callback fetch(conn :: term(), source :: [String.t()]) ::
              {:ok, Enumerable.t()} | {:error, term()}
end
