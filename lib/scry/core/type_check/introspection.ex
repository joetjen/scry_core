defmodule Scry.Core.TypeCheck.Introspection do
  @moduledoc """
  The introspection-assisted half of the compile-time type
  system -- needs a live connection, so unlike `Scry.Core.TypeCheck`
  itself, this is never run automatically inside `Scry.Core.parse/1`'s
  own pipeline. A caller invokes `check_with_introspection/3` explicitly
  between `Scry.Core.parse/1` and `Scry.Core.Executor.run/3,4` (see
  `Scry.Core.check_types/3`, the public facade for this).

  Collects every real source name referenced anywhere in the document
  (via `Scry.Core.TypeCheck.Nodes.collect/3`, the same recursion targets
  `Scry.Core.TypeCheck.check/1` itself walks), excludes any name that
  already has an inline `TYPE` declaration and any name that's a `WITH`
  binding key (not a real backend source at all), then -- if
  `engine_module` exports the optional `describe_source/2` callback
  (`Scry.Core.EngineBehaviour`) -- calls it once per remaining source and
  merges the result into the document's own `type_decls` map before
  delegating to `Scry.Core.TypeCheck.check/2`.

  **Inline wins entirely if present at all -- no field-by-field merge.**
  A source with even one hand-declared field is filtered out of the
  introspection candidate set entirely; introspection only ever fills a
  *totally* undeclared source. This is simpler than inventing a merge-
  precedence rule for the two things introspection structurally can
  never discover on its own (a `kind` tag, a `JSON`/`DXN`/`DXNB` shape)
  that a hand-written declaration can -- but it's a real, worth-stating
  tradeoff: declaring even one field by hand for a source opts that
  whole source out of introspection for every other column.
  """

  alias Scry.Core.{CombinedQuery, Query, TypeCheck, TypeCheck.Nodes}

  @doc """
  Runs `Scry.Core.TypeCheck.check/2` against `query_or_combined`'s own
  inline `type_decls`, augmented with a `describe_source/2`-introspected
  entry for every real source referenced that has no inline declaration
  at all. `engine_module` not implementing `describe_source/2` is not an
  error -- introspection contributes nothing, and checking proceeds with
  just the inline declarations, identical to calling `TypeCheck.check/1`
  directly.

  Returns `{:error, {:introspection_failed, source, detail}}` if
  `describe_source/2` returns `{:error, {:introspection_error, detail}}`
  for any candidate source -- a genuine backend-level failure, not mere
  absence (`{:error, :not_found}` is absorbed silently instead, the same
  "absence isn't a contradiction" posture used elsewhere in this
  codebase for an unmatched fragment/`TYPE` name).
  """
  @spec check_with_introspection(Query.t() | CombinedQuery.t(), module(), term()) ::
          :ok | {:error, term()}
  def check_with_introspection(query_or_combined, engine_module, conn) do
    inline_type_decls = top_type_decls(query_or_combined)
    with_names = top_with_bindings(query_or_combined) |> Map.keys() |> MapSet.new()

    candidate_sources =
      query_or_combined
      |> Nodes.collect(MapSet.new(), fn query, acc ->
        case single_source_name(query.source) do
          nil -> acc
          name -> MapSet.put(acc, name)
        end
      end)
      |> MapSet.difference(with_names)
      |> Enum.reject(&Map.has_key?(inline_type_decls, &1))

    with {:ok, introspected_decls} <- introspect_all(candidate_sources, engine_module, conn) do
      TypeCheck.check(query_or_combined, Map.merge(introspected_decls, inline_type_decls))
    end
  end

  defp single_source_name([name]), do: name
  defp single_source_name(_source), do: nil

  defp top_type_decls(%Query{type_decls: type_decls}), do: type_decls
  defp top_type_decls(%CombinedQuery{type_decls: type_decls}), do: type_decls

  defp top_with_bindings(%Query{with_bindings: with_bindings}), do: with_bindings
  defp top_with_bindings(%CombinedQuery{with_bindings: with_bindings}), do: with_bindings

  defp introspect_all(sources, engine_module, conn) do
    if function_exported?(engine_module, :describe_source, 2) do
      Enum.reduce_while(sources, {:ok, %{}}, fn source, {:ok, acc} ->
        case engine_module.describe_source(conn, source) do
          {:ok, fields} ->
            {:cont, {:ok, Map.put(acc, source, type_decl_from_fields(source, fields))}}

          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, {:introspection_error, detail}} ->
            {:halt, {:error, {:introspection_failed, source, detail}}}
        end
      end)
    else
      {:ok, %{}}
    end
  end

  defp type_decl_from_fields(source, fields) do
    %{
      name: source,
      kind: nil,
      fields:
        Enum.map(fields, fn %{name: name, nullable: nullable?, scalar: scalar} ->
          {name, introspected_type_expr(scalar, nullable?)}
        end)
    }
  end

  @spec introspected_type_expr(
          :integer | :float | :string | :boolean | :json | :unknown,
          boolean()
        ) ::
          Query.type_expr()
  defp introspected_type_expr(scalar, nullable?) do
    base = {:named, scalar_type_name(scalar), nil}
    if nullable?, do: {:nullable, base}, else: base
  end

  defp scalar_type_name(:integer), do: "Int"
  defp scalar_type_name(:float), do: "Float"
  defp scalar_type_name(:string), do: "String"
  defp scalar_type_name(:boolean), do: "Bool"
  defp scalar_type_name(:json), do: "JSON"
  defp scalar_type_name(:unknown), do: "Unknown"
end
