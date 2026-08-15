defmodule Scry.Core.WithCycleCheck do
  @moduledoc """
  Static cycle detection over a document's own `WITH` bindings
  (`Scry.Core.Query.t/0`'s own `with_bindings`), invoked
  once from `Scry.Core.Actions`' own `handle_rule(:document, ...)` before
  `Scry.Core.parse/1` ever returns.

  A `WITH` reference is resolved at *execution* time (`Scry.Core.
  QueryOps.run_document/4` intercepts any query whose own `source` is
  exactly `[name]` for a declared binding, running that binding instead
  of calling the real engine's `execute/3`) -- there's no distinguishing
  sigil the parser could
  reject an *undefined* reference with, unlike a `FRAGMENT` spread's own
  `...name`, so this module only ever checks for *cycles*, never for
  undefined names (a name that isn't a `WITH` binding is just an ordinary
  real source, not an error). A cycle is different: `WITH a = SELECT b
  {...}` and `WITH b = SELECT a {...}` both existing would make
  `Scry.Core.Executor.run/3` recurse into itself forever the moment either
  is referenced -- a real, `raise`-free infinite loop, not a data-shaped
  runtime problem an `{:error, _}` return from execution could ever
  surface cleanly. Catching it here, before any row is fetched, is the
  same "fail fast, at compile time, with a clear message" posture
  `Scry.Core.FragmentResolver`'s own cycle check already established for
  fragment spreads.

  **`WITH RECURSIVE` is the one deliberate
  exception**: a binding whose own value is `{:recursive, query}` is
  allowed to reference *itself* directly (that's the entire point --
  `Scry.Core.QueryOps.resolve_source/5` runs a real, terminating
  fixpoint loop for it, not an infinite one) -- excluded from its own
  dependency list before the ordinary walk below ever sees it, so a
  recursive binding referencing *itself* is not flagged, but one
  participating in a longer cycle through some *other* binding still is,
  exactly as strictly as before.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Checks every declared binding in `with_bindings` for a cycle (through
  one or more *other* `WITH` bindings, not just direct self-reference) --
  `query.source` at any depth, including inside a nested `SELECT` body
  item, counts as a reference. Returns `:ok`, or `{:error, {:with_cycle,
  names}}` with the cycle spelled out in the order it was found.
  """
  @spec check(%{
          String.t() =>
            Query.t() | CombinedQuery.t() | {:recursive, Query.t() | CombinedQuery.t()}
        }) :: :ok | {:error, {:with_cycle, [String.t()]}}
  def check(with_bindings) do
    Enum.reduce_while(Map.keys(with_bindings), :ok, fn name, :ok ->
      case visit(name, with_bindings, []) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp visit(name, with_bindings, stack) do
    if name in stack do
      {:error, {:with_cycle, Enum.reverse([name | stack])}}
    else
      {recursive?, query_or_combined} = unwrap(Map.fetch!(with_bindings, name))

      query_or_combined
      |> referenced_bindings(with_bindings)
      |> Enum.reject(&(recursive? and &1 == name))
      |> Enum.reduce_while(:ok, fn dep, :ok ->
        case visit(dep, with_bindings, [name | stack]) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp unwrap({:recursive, value}), do: {true, value}
  defp unwrap(value), do: {false, value}

  # Every source name this query references, at any nesting depth,
  # filtered down to only the ones that are themselves `WITH` bindings --
  # an ordinary real-source reference isn't a dependency for cycle
  # detection at all.
  defp referenced_bindings(query_or_combined, with_bindings) do
    query_or_combined
    |> all_source_names()
    |> Enum.filter(&Map.has_key?(with_bindings, &1))
  end

  defp all_source_names(%Query{source: [name], select: items}),
    do: [name | nested_source_names(items)]

  defp all_source_names(%Query{select: items}), do: nested_source_names(items)

  defp all_source_names(%CombinedQuery{left: left, right: right}),
    do: all_source_names(left) ++ all_source_names(right)

  defp nested_source_names(items) do
    Enum.flat_map(items, fn
      %Query{} = nested -> all_source_names(nested)
      _other -> []
    end)
  end
end
