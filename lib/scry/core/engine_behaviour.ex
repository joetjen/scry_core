defmodule Scry.Core.EngineBehaviour do
  @moduledoc """
  The contract every Scry storage adapter implements: given the whole,
  as-parsed query document -- a `%Scry.Core.Query{}` or `%Scry.Core.
  CombinedQuery{}`, `WITH` bindings and nested/correlated `SELECT`
  body items included, exactly as `Scry.Core.parse/1` produced it --
  compute the *entire* answer and either return it or decline it
  outright. There is no second, automatic pass anywhere in this
  ecosystem that re-applies any of this afterward: `execute/3` is
  authoritative for whatever it accepts, not a hint an engine may only
  partially honor. This replaces the earlier `fetch/2,3,4`/
  `aggregate/5` contract entirely (a genuinely different, stricter
  trust model -- see "Why this replaces fetch/aggregate" below), not
  an addition to it.

  ## What an engine actually receives

  `Scry.Core.Executor.run/3,4` (the only place this callback is ever
  called from) hands `query` through completely unmodified -- it may
  be a `%Scry.Core.CombinedQuery{}` (`UNION`/`INTERSECT`/`EXCEPT`), a
  `%Scry.Core.Query{}` whose own `source` names a `WITH` binding
  instead of a real table, or a `%Scry.Core.Query{}` whose `select`
  contains a nested, possibly-correlated `%Scry.Core.Query{}` of its
  own. None of this is pre-decomposed for the engine. This is
  deliberate: a correlated nested `SELECT` maps naturally onto a
  native SQL `JOIN`, a `WITH` binding onto a native CTE, and a
  combinator onto a native `UNION`/`INTERSECT`/`EXCEPT` -- an engine
  sophisticated enough to translate the *whole* document into one
  native query should be free to, rather than have `scry_core`
  pre-decompose it into pieces first and lose that opportunity.

  An engine that isn't that sophisticated yet (or hasn't implemented a
  specific construct) doesn't have to reimplement Scry's own generic
  semantics for it: `Scry.Core.QueryOps.run_document/4` implements
  `WITH`/correlated-nested-`SELECT`/combinator resolution generically,
  recursing back into `execute/3` for whatever flat leaf queries
  remain (`Scry.Core.QueryOps.run_flat/3`, called once a leaf's own
  source is resolved), and `run_flat/3` alone is available for an
  engine that has already reduced a flat query down to a plain row
  enumerable of its own and wants the rest -- `GROUP BY`/aggregates/
  sorting/projection/casts/window functions -- computed for it. Both
  are ordinary functions an engine calls from inside its own
  `execute/3`, entirely its own choice; `scry_core` never calls either
  on an engine's behalf.

  ## Why this replaces `fetch`/`aggregate` entirely

  The earlier contract kept two trust tiers: `fetch/3`/`fetch/4` were
  *lenient* (`Scry.Core.Executor` unconditionally re-applied its whole
  pipeline to whatever came back, so an engine's own translation only
  ever had to be safe, never complete), and `aggregate/5` was
  *authoritative but narrow* (no `avg`, no `HAVING`, no `ORDER BY`/
  `LIMIT` pushdown at all -- sorting and pagination always still ran
  in Elixir afterward, even for a correctly pushed-down aggregate).
  Measured directly: even with `aggregate/5` pushdown in play, a
  `GROUP BY`-heavy query against a real SQLite-backed table was still
  11-15x slower than the equivalent raw SQL, because the lenient half
  of the contract meant most real queries still paid for a full
  Elixir-side re-walk regardless of what got translated, and the
  authoritative half never covered enough of a query's own shape to
  eliminate that re-walk for the rest. Closing that gap for real needs
  an engine trusted to own the *entire* query and its own result, with
  nothing downstream re-verifying or re-computing any of it -- which
  is exactly what made the old contract's automatic re-verification
  (the thing that made `fetch/3`/`fetch/4` safe to add incrementally)
  impossible to keep. There is no engine-authored partial answer this
  contract can safely accept; an engine that can't fully and correctly
  compute a given `query` must decline it, not return something
  narrower for something else to finish.

  ## What a kind package must guarantee

  A `:variant` body item and a populated `query.variant` are the one
  thing `execute/3` must never see: a kind package (`scry_time_series`,
  ...) is required to fully lower its own EP1/EP2 vocabulary into
  ordinary core AST before ever calling `Scry.Core.Executor.run/3,4`,
  exactly what every existing kind package already does.
  """

  @typedoc "A single result row -- either a plain string-keyed map, matching `Scry.Core.Query`'s own path segments, or a `Scry.Core.Row.t()`."
  @type row :: %{optional(String.t()) => term()} | Scry.Core.Row.t()

  @typedoc """
  Why an engine declined or failed a query.

  `{:unsupported, detail}` means the engine understood `query` but
  deliberately doesn't (yet, or ever) implement that shape --
  `detail` is a small, documented, closed-ish vocabulary describing
  *which* construct was rejected, e.g. `{:construct, :window_function}`,
  `{:construct, :rollup}`, `{:construct, :cube}`, `{:construct,
  :nested_select}`, `{:construct, :with_binding}`, `{:aggregate,
  "avg"}`, `{:predicate, :match}`, `{:distinct_argument, expr}`.
  `{:query_error, detail}` means the engine attempted the query and it
  genuinely failed against the real backend (an invalid source, a
  driver-level error, a value that failed to bind) -- a caller can and
  should treat these two differently: `:unsupported` is "try a
  different engine or a different query shape", `:query_error` is
  "this specific attempt failed".
  """
  @type error :: {:unsupported, term()} | {:query_error, term()}

  @doc """
  Computes the *entire* answer for `query` against `conn`, resolving
  any `{:param, name}` reference against `params`. `query` is exactly
  what `Scry.Core.parse/1` produced for the document being run --
  see this module's own moduledoc for what that can include and how
  to delegate any of it to `Scry.Core.QueryOps` instead of
  reimplementing it.

  Returns `{:ok, Enumerable.t()}` of already-fully-realized output
  rows on success. A plain list already satisfies `Enumerable.t()`; a
  genuinely lazy/streaming engine may return a `Stream` instead, and
  `Scry.Core.Executor` wraps whatever comes back in a `Scry.Core.
  Cursor.t()` for the caller -- an engine is never required to
  construct one directly.

  Returns `{:error, error()}` (see `t:error/0`) when the engine either
  declines `query`'s own shape outright or attempts it and fails --
  there is no partial-success return value, and nothing downstream
  re-applies or re-verifies whatever this callback returns.
  """
  @callback execute(
              conn :: term(),
              query :: Scry.Core.Query.t() | Scry.Core.CombinedQuery.t(),
              params :: %{String.t() => term()}
            ) :: {:ok, Enumerable.t()} | {:error, error()}

  @typedoc """
  A coarse, best-effort description of what an engine's `execute/3`
  tends to accept -- documentation/introspection only, e.g. for a
  future `mix scry.explain`-style tool or an application routing a
  query to one of several engines ahead of time. Open map, may grow
  new keys in a future, non-breaking increment.
  """
  @type capabilities :: %{
          optional(:aggregates) => MapSet.t(String.t()),
          optional(:window_functions) => boolean(),
          optional(:rollup_cube) => boolean(),
          optional(:exact_avg) => boolean(),
          optional(:nested_select) => boolean(),
          optional(:with_bindings) => boolean()
        }

  @doc """
  **Optional, and never consulted by `scry_core` itself before calling
  `execute/3`.** A real "would you accept this exact query" oracle
  needs essentially the same eligibility logic `execute/3` itself
  already has to run to decide whether to decline -- duplicating that
  logic into a second callback risks exactly the "the planner says
  yes, the executor says no" bug class, for a benefit (avoiding one
  cheap, side-effect-free `{:error, {:unsupported, _}}` round trip)
  that's marginal for any well-written engine. This exists purely for
  external tooling to introspect, coarsely, what an engine tends to
  support -- never as a pre-flight check `execute/3`'s own contract
  depends on.
  """
  @callback capabilities(conn :: term()) :: capabilities()

  @optional_callbacks capabilities: 1
end
