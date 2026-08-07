defmodule Scry.Core.FragmentResolver do
  @moduledoc """
  Expands `{:spread, name}` placeholders (`Scry.Core.Actions`' own
  `handle_rule(:spread, ...)`) into the named `FRAGMENT`'s own body-item
  list, in place -- the desugaring lang_spec §5.11/§9's `...<fragment-
  name>` describes ("GraphQL-style", per that section's own framing).
  Invoked once, by `Scry.Core.Actions`' own `handle_rule(:document, ...)`,
  after both the top-level `select` and every `FRAGMENT` declaration have
  already been evaluated into real terms -- not by `handle_rule(:spread,
  ...)` itself, since a spread may reference a `FRAGMENT` declared later
  in the same document (lang_spec gives no ordering requirement between
  a `FRAGMENT` and its uses), which a single bottom-up pass over the
  parse tree can't see ahead of.

  `{:spread, name}` never survives past `resolve/2` -- a caller only
  ever sees `Query.body_item()`'s own real shapes (`{:field, ...}`,
  `{:computed, ...}`, a nested `%Query{}`, `{:variant, ...}`) in the
  struct `Scry.Core.parse/1` hands back, exactly as if the spread's own
  target fragment's body had been written out by hand at that position.

  Three real error conditions, each surfaced as `{:error, reason}` (the
  same raw-tuple convention `Scry.Core.Actions`' own `handle_token`
  clauses already use, not a wrapped `%Ichor.Error{}` -- see that
  module's own moduledoc):

    - `{:undefined_fragment, name}` -- a spread names a `FRAGMENT` that
      was never declared anywhere in the document.
    - `{:fragment_cycle, [name, ...]}` -- a `FRAGMENT` spreads itself,
      directly or transitively (through one or more other `FRAGMENT`s).
      Unlike a nested `SELECT`, a `FRAGMENT` is pure textual substitution
      with no runtime step in between to make a cycle merely expensive
      instead of genuinely infinite -- this has to be a compile error,
      not a runtime concern the way `REQUIRED`'s own re-fetch cost is.
    - `{:duplicate_fragment, name}` -- caught earlier, by
      `Scry.Core.Actions`' own `build_fragment_map/1`, before this module
      ever sees the map; listed here only so every `document`-level
      compile error is documented in one place.

  Fragments are resolved once each, independent of how many times (or
  where) they're spread -- a `FRAGMENT` may itself contain a nested
  `SELECT` with its own spreads, or spread a second `FRAGMENT`, and
  either is expanded exactly the same way a top-level query's own body
  is, recursively.

  A document's own top-level result may be a `%Scry.Core.CombinedQuery{}`
  instead of a plain `%Query{}` (lang_spec §5.4's `UNION`/`INTERSECT`/
  `EXCEPT`, `Scry.Core.CombinedQuery`'s own moduledoc) -- `resolve/2`'s
  own second clause recurses into both `left`/`right` (each independently
  either shape), so a `FRAGMENT` spread works identically on *either*
  side of a combinator, not just inside a plain query.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @typedoc "Raw FRAGMENT declarations, name => (possibly spread-containing) body-item list."
  @type fragments :: %{String.t() => [Query.body_item() | {:spread, String.t()}]}

  @doc """
  Resolves every `{:spread, name}` placeholder in `query_or_combined`'s
  own body (recursively, including inside any nested `SELECT`, and, for
  a `%CombinedQuery{}`, on both sides of the combinator) against
  `fragments`.
  """
  @spec resolve(Query.t() | CombinedQuery.t(), fragments()) ::
          {:ok, Query.t() | CombinedQuery.t()} | {:error, term()}
  def resolve(%Query{} = query, fragments) do
    with {:ok, select, _resolved} <- expand_items(query.select, fragments, [], %{}) do
      {:ok, %Query{query | select: select}}
    end
  end

  def resolve(%CombinedQuery{} = combined, fragments) do
    with {:ok, left} <- resolve(combined.left, fragments),
         {:ok, right} <- resolve(combined.right, fragments) do
      {:ok, %CombinedQuery{combined | left: left, right: right}}
    end
  end

  # `resolved` memoizes each fragment's own fully-expanded body the first
  # time it's spread, so a fragment referenced more than once (from
  # different places in the document) is only ever walked once.
  defp expand_items(items, fragments, stack, resolved) do
    items
    |> Enum.reduce_while({:ok, [], resolved}, fn item, {:ok, acc, resolved} ->
      case expand_item(item, fragments, stack, resolved) do
        {:ok, expanded, resolved} -> {:cont, {:ok, [expanded | acc], resolved}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, resolved} -> {:ok, acc |> Enum.reverse() |> List.flatten(), resolved}
      err -> err
    end
  end

  defp expand_item({:spread, name}, fragments, stack, resolved) do
    with {:ok, body, resolved} <- expand_fragment(name, fragments, stack, resolved) do
      {:ok, body, resolved}
    end
  end

  defp expand_item(%Query{} = nested, fragments, stack, resolved) do
    with {:ok, select, resolved} <- expand_items(nested.select, fragments, stack, resolved) do
      {:ok, [%Query{nested | select: select}], resolved}
    end
  end

  defp expand_item(item, _fragments, _stack, resolved), do: {:ok, [item], resolved}

  defp expand_fragment(name, fragments, stack, resolved) do
    cond do
      Map.has_key?(resolved, name) ->
        {:ok, Map.fetch!(resolved, name), resolved}

      name in stack ->
        {:error, {:fragment_cycle, Enum.reverse([name | stack])}}

      true ->
        case Map.fetch(fragments, name) do
          {:ok, raw_body} ->
            with {:ok, expanded, resolved} <-
                   expand_items(raw_body, fragments, [name | stack], resolved) do
              {:ok, expanded, Map.put(resolved, name, expanded)}
            end

          :error ->
            {:error, {:undefined_fragment, name}}
        end
    end
  end
end
