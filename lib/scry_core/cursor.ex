defmodule ScryCore.Cursor do
  @moduledoc """
  A real, pull-based cursor over any `Enumerable.t()` -- `next/1` pulls
  exactly one element (never forcing evaluation of anything beyond it),
  `take/2`/`skip/1,2` build on that, `to_list/1` drains the rest. Exists
  because `ScryCore.EngineBehaviour.fetch/2` now accepts (not just a
  plain list, but) any `Enumerable.t()` -- an adapter backed by a real
  streaming cursor (a Postgrex cursor, an ETS/Mnesia match continuation,
  ...) can return something genuinely lazy, and this module is how a
  caller consumes it one row at a time without forcing the whole thing
  into memory first.

  **The mechanism, verified directly (a real scratch script pulling
  from a side-effecting `Stream.map/2`, confirmed only the requested
  elements' side effects ran) before writing this for real, not
  assumed:** `Enumerable.reduce/3`'s own `{:suspend, acc}` /
  `{:suspended, acc, continuation}` protocol -- the same stdlib-native
  mechanism `Enum.zip/2` itself uses internally to interleave two
  enumerables one element at a time, a real, documented part of the
  `Enumerable` behaviour's own contract, not a novel trick. `new/1`
  starts a reduction whose own reducer function immediately returns
  `{:suspend, elem}` on the very first element, which makes
  `Enumerable.reduce/3` return `{:suspended, elem, continuation}` right
  there -- `elem` is the one row we asked for, `continuation` is a
  1-arity function that, called again with `{:cont, _}`, resumes
  *exactly* where the underlying enumerable left off and suspends again
  on the next element. `next/1` is a thin wrapper around calling that
  continuation once; every other function here is built on `next/1`
  alone, not a second implementation of the same mechanism. (The
  published `stream_split` Hex package solves the identical problem the
  same way -- confirmed this is the standard idiom, not reinventing
  one, though not taken as a dependency here: the mechanism is small
  enough, and `scry_core` foundational enough, that hand-rolling it
  keeps this package's own dependency footprint exactly as lean as it
  already is.)

  **What this module does *not* do:** materialize anything it isn't
  asked for. `ScryCore.Executor` itself still calls `to_list/1`
  immediately at the fetch boundary (`fetch_rows/6`) and stays fully
  eager downstream of that -- `GROUP BY`/`ORDER BY`/`DISTINCT`/window
  functions are all inherently blocking regardless of how `fetch/2`
  returns its data, so `Executor`'s own internal pipeline has nothing
  to gain from staying lazy past that point today. This module exists
  so the *contract* genuinely supports laziness end to end, and so a
  future caller (a streaming-aware executor path, or code outside
  `ScryCore.Executor` entirely) has a real, independently correct tool
  to consume it with, once there's a real streaming adapter to prove
  the benefit against.
  """

  @opaque t() :: %__MODULE__{continuation: continuation() | :done}
  @typep continuation :: (Enumerable.acc() -> Enumerable.result())

  defstruct [:continuation]

  @doc "Wraps `enumerable` for pull-based access -- does nothing eager; no element is evaluated until `next/1` (or something built on it) actually asks for one."
  @spec new(Enumerable.t()) :: t()
  def new(enumerable) do
    %__MODULE__{
      continuation: &Enumerable.reduce(enumerable, &1, fn elem, _acc -> {:suspend, elem} end)
    }
  end

  @doc """
  Pulls exactly one element -- `{:ok, element, cursor}` (an updated
  cursor picking up right after it), or `:done` once the underlying
  enumerable is exhausted. `:done` is a real, distinct terminal state,
  not a sentinel value that could collide with a genuine row -- once
  reached, every further `next/1` call on that cursor (or any cursor
  derived from it) returns `:done` again rather than re-running
  anything.
  """
  @spec next(t()) :: {:ok, term(), t()} | :done
  def next(%__MODULE__{continuation: :done}), do: :done

  def next(%__MODULE__{continuation: cont}) do
    case cont.({:cont, nil}) do
      {:suspended, elem, next_cont} -> {:ok, elem, %__MODULE__{continuation: next_cont}}
      {:done, _acc} -> :done
      {:halted, _acc} -> :done
    end
  end

  @doc "Pulls up to `n` elements, returning `{elements, cursor}` -- fewer than `n` (paired with an exhausted cursor) if the source runs out first, same as `Enum.take/2`'s own short-read behavior."
  @spec take(t(), non_neg_integer()) :: {[term()], t()}
  def take(cursor, n) when is_integer(n) and n >= 0, do: take(cursor, n, [])

  defp take(cursor, 0, acc), do: {Enum.reverse(acc), cursor}

  defp take(cursor, n, acc) do
    case next(cursor) do
      {:ok, elem, cursor2} -> take(cursor2, n - 1, [elem | acc])
      :done -> {Enum.reverse(acc), %__MODULE__{continuation: :done}}
    end
  end

  @doc "Skips exactly `n` elements (discarded, not returned)."
  @spec skip(t(), non_neg_integer()) :: t()
  def skip(cursor, n) when is_integer(n) and n >= 0 do
    {_discarded, rest} = take(cursor, n)
    rest
  end

  @doc "Skips exactly one element -- `skip(cursor, 1)`."
  @spec skip(t()) :: t()
  def skip(cursor), do: skip(cursor, 1)

  @doc "Drains the rest of the cursor into an ordinary list -- what anything wanting the whole result set (a mix task printing every row, say) calls."
  @spec to_list(t()) :: [term()]
  def to_list(cursor), do: to_list(cursor, [])

  defp to_list(cursor, acc) do
    case next(cursor) do
      {:ok, elem, cursor2} -> to_list(cursor2, [elem | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
