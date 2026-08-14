defmodule Scry.Core.TypeCheck.Nodes do
  @moduledoc """
  The one shared tree-walk over a parsed document's own query nodes,
  reused by both `Scry.Core.TypeCheck` (halt on the first error) and
  `Scry.Core.TypeCheck.Introspection` (collect, never halt) -- the same
  recursion targets `Scry.Core.WithCycleCheck` and `Scry.TimeSeries.
  Executor.rewrite/2` already use for an analogous whole-document walk:
  the top-level result itself, every nested `%Scry.Core.Query{}` body
  item inside `select` (recursively -- a nested query may itself nest
  further), every `with_bindings` value (a `Query.t()`, a
  `CombinedQuery.t()` now that `WITH`/`WITH RECURSIVE` may bind a
  combinator too, or `{:recursive, Query.t() | CombinedQuery.t()}` --
  unwrapped before walking, same as an ordinary binding either way,
  since a `WITH RECURSIVE` binding's own base/recursive cases still
  deserve the identical compile-time checks any other query gets), and
  both sides of a `%CombinedQuery{}` (each independently either shape).

  `with_bindings`/`type_decls` are only ever populated on the document's
  own top-level result (`Scry.Core.Actions`' own `handle_rule(:document,
  ...)`, `Query.t()`'s own moduledoc) -- never on a nested query or an
  internal `CombinedQuery` node from a longer combinator chain. This
  module reads `with_bindings` exactly once, off whichever struct is
  passed to it, for that reason; a caller wanting `type_decls` handles
  that the same way (read once, off the same top-level struct, thread
  it through the walk's own callback closure) -- this module has no
  opinion on `type_decls` at all, it only walks structure.

  Two entry points, not one generic combinator forced to serve both
  shapes of use: `each/2` halts on the first non-`:ok` result (modeled
  directly on `Scry.Core.WithCycleCheck`'s own `Enum.reduce_while`
  idiom), `collect/3` never halts (an ordinary fold, no early-exit
  machinery needed at all). Trying to unify these into one primitive
  would need a caller-visible "did we halt" sentinel neither consumer
  actually wants to think about.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Calls `check_fun.(query)` for every query node in `query_or_combined`,
  depth-first, halting and returning the first `{:error, reason}` any
  call produces. Returns `:ok` if every node checks out.
  """
  @spec each(Query.t() | CombinedQuery.t(), (Query.t() -> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def each(query_or_combined, check_fun) do
    with :ok <- visit_each(query_or_combined, check_fun) do
      query_or_combined
      |> top_with_bindings()
      |> Map.values()
      |> Enum.reduce_while(:ok, fn bound, :ok ->
        case visit_each(unwrap_binding(bound), check_fun) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  defp visit_each(%Query{select: items} = query, check_fun) do
    with :ok <- check_fun.(query) do
      Enum.reduce_while(items, :ok, fn
        %Query{} = nested, :ok ->
          case visit_each(nested, check_fun) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end

        _other, :ok ->
          {:cont, :ok}
      end)
    end
  end

  defp visit_each(%CombinedQuery{left: left, right: right}, check_fun) do
    with :ok <- visit_each(left, check_fun) do
      visit_each(right, check_fun)
    end
  end

  @doc """
  Folds `collect_fun.(query, acc)` over every query node in
  `query_or_combined`, depth-first, same recursion targets as `each/2`.
  Never halts early -- there's no such thing as a "wrong" node to fold
  over here, only ones already visited or not yet.
  """
  @spec collect(Query.t() | CombinedQuery.t(), acc, (Query.t(), acc -> acc)) :: acc
        when acc: term()
  def collect(query_or_combined, acc, collect_fun) do
    acc = visit_collect(query_or_combined, acc, collect_fun)

    query_or_combined
    |> top_with_bindings()
    |> Map.values()
    |> Enum.reduce(acc, &visit_collect(unwrap_binding(&1), &2, collect_fun))
  end

  defp visit_collect(%Query{select: items} = query, acc, collect_fun) do
    acc = collect_fun.(query, acc)

    Enum.reduce(items, acc, fn
      %Query{} = nested, acc -> visit_collect(nested, acc, collect_fun)
      _other, acc -> acc
    end)
  end

  defp visit_collect(%CombinedQuery{left: left, right: right}, acc, collect_fun) do
    acc
    |> then(&visit_collect(left, &1, collect_fun))
    |> then(&visit_collect(right, &1, collect_fun))
  end

  defp top_with_bindings(%Query{with_bindings: wb}), do: wb
  defp top_with_bindings(%CombinedQuery{with_bindings: wb}), do: wb

  defp unwrap_binding({:recursive, value}), do: value
  defp unwrap_binding(value), do: value
end
