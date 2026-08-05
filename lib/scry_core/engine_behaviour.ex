defmodule ScryCore.EngineBehaviour do
  @moduledoc """
  The shared execution scaffold every kind's own engine behaviour is
  meant to build on top of (impl_spec.md §2: "core exposes the shared
  execution scaffold every kind's own behaviour builds on top of").
  Covers only what filtering and projecting a `%ScryCore.Query{}`
  actually needs from an adapter -- fetching a source's rows.
  Everything else (`where`/`select` evaluation) is core's own job,
  `ScryCore.Executor`, not an adapter's, so it's not part of this
  contract at all.

  A kind-specific behaviour (`scry_time_series`'s own, once it exists)
  is expected to extend this shape with callbacks for whatever
  EP1/EP2 constructs that kind's own grammar fragment contributes --
  nothing here assumes an adapter only ever implements the one
  callback below.

  No pushdown support yet -- `fetch/2` takes just a source path, not
  the query's `wheres`, so every adapter (including a real one) fetches
  every row for a source and lets `ScryCore.Executor` filter
  client-side. Always correct, not necessarily efficient; a real
  adapter wanting to push predicates down to its own store is a later
  optimization on top of this same contract, not a different one.
  """

  @typedoc "A single result row -- string keys, matching `ScryCore.Query`'s own path segments."
  @type row :: %{optional(String.t()) => term()}

  @doc "Fetches every row for `source` (a dotted path, e.g. `[\"orders\"]`) from `conn`."
  @callback fetch(conn :: term(), source :: [String.t()]) ::
              {:ok, [row()]} | {:error, term()}
end
