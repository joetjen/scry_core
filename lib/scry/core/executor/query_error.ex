defmodule Scry.Core.Executor.QueryError do
  @moduledoc """
  Raised while pulling from a `%Scry.Core.Cursor{}` returned by `Scry.Core.
  Executor.run/4`, for a failure that can only be discovered mid-stream --
  today, exclusively `project_item/8`'s own `{:variant, _}` clause (a
  kind's own EP1(b)/(c)/(d) body-item construct core doesn't know how to
  project, `{:error, {:unsupported_body_item, item}}` in this module's
  own pre-existing, still-unchanged internal shape).

  **Why a raise, not a return value, for this specific case:** `run/4`'s
  own contract changed from `{:ok, [row()]} | {:error, term()}` to `{:ok,
  Cursor.t()} | {:error, term()}` so the whole pipeline can genuinely stay
  lazy end to end (`Scry.Core.Cursor`'s own moduledoc has the full
  reasoning) -- but `Cursor.next/1`'s own contract (`{:ok, term(), t()} |
  :done`) has no room for a third "here's an error instead" outcome
  without complicating every consumer of *any* cursor, not just this
  module's own. A raised exception is the same "some failures surface as
  real exceptions, not `{:error, _}` tuples" posture this module already
  has elsewhere (a missing external parameter, an aggregate over a `nil`
  value -- both raise `ArgumentError` today, unchanged) -- this is that
  same posture, just reached through a lazily-pulled cursor instead of an
  eagerly-evaluated call.

  **This is invisible at every *internal* boundary that already needs a
  concrete list anyway** (a nested `SELECT` embedded into its own parent
  row, either side of `UNION`/`INTERSECT`/`EXCEPT`) -- `Scry.Core.Executor`'s
  own private `drain_result/1` catches exactly this exception at each such
  boundary and converts it straight back into the classic `{:error,
  reason}` tuple every *other* internal error path already returns, so
  `REQUIRED`, `combine_rows/3`, and everything built on top of them needs
  zero further changes. It only ever reaches an external caller as a real
  exception when *that caller* pulls far enough into the *top-level*
  cursor to hit it.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "query execution failed while pulling a result row: #{inspect(reason)}"
end
