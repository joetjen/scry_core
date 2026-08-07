defmodule ScryCore.Query.From do
  @moduledoc """
  `ScryCore.Query.from/2`'s own implementation -- kept out of
  `ScryCore.Query` itself so that module's own moduledoc (documenting
  the struct/Layer 1) doesn't have to also carry this macro's own
  keyword-clause dispatch. `ScryCore.Query.from/2` is a one-line
  delegation to `build/3` here.

  No Ecto-style "try compile-time struct build, fall back to a runtime
  `Module.apply` call" split (`Ecto.Query.Builder.apply_query/4`'s own
  mechanism, confirmed by reading the real source before designing
  this) -- Layer 1's own functions (`ScryCore.Query.new/1`, `where/2`,
  ...) are plain, unconditionally-runtime functions already, so this
  macro always emits one quoted pipeline of Layer 1 calls and lets
  ordinary Elixir compilation handle whether `source` or any escaped
  piece is itself a compile-time literal or a runtime expression --
  no special-casing needed either way.
  """

  alias ScryCore.Query.Escape

  @clause_keys ~w(where having group_by order_by distinct limit offset select)a

  @doc false
  @spec build(Macro.t(), Macro.t(), Macro.Env.t()) :: Macro.t()
  def build({:in, _, [var_ast, source_ast]}, opts, env) when is_list(opts) do
    bound_var = bound_var_name!(var_ast)

    unrecognized = Keyword.keys(opts) -- @clause_keys

    unless unrecognized == [] do
      raise ArgumentError,
            "from/2 doesn't recognize #{Enum.map_join(unrecognized, ", ", &"`#{&1}:`")} -- " <>
              "expected one of: #{Enum.map_join(@clause_keys, ", ", &"`#{&1}:`")}"
    end

    base = quote do: ScryCore.Query.new(List.wrap(unquote(source_ast)))

    Enum.reduce(opts, base, fn {key, value_ast}, acc ->
      quote do: unquote(acc) |> unquote(clause_call(key, value_ast, bound_var, env))
    end)
  end

  def build(other, _opts, _env) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid from/2 header -- expected `var in source`"
  end

  defp bound_var_name!({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name

  defp bound_var_name!(other) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid bound variable -- expected a bare local " <>
            "variable, e.g. `u` in `from u in \"users\"`"
  end

  defp clause_call(:where, value_ast, bound_var, env) do
    escaped = Escape.escape_predicate(value_ast, bound_var, env)
    quote do: ScryCore.Query.where(unquote(escaped))
  end

  defp clause_call(:having, value_ast, bound_var, env) do
    escaped = Escape.escape_predicate(value_ast, bound_var, env)
    quote do: ScryCore.Query.having(unquote(escaped))
  end

  defp clause_call(:group_by, value_ast, bound_var, env) when is_list(value_ast) do
    escaped = Enum.map(value_ast, &Escape.escape_path(&1, bound_var, env))
    quote do: ScryCore.Query.group_by(unquote(escaped))
  end

  defp clause_call(:order_by, value_ast, bound_var, env) when is_list(value_ast) do
    escaped =
      Enum.map(value_ast, fn
        {dir, path_ast} when dir in [:asc, :desc] ->
          path = Escape.escape_path(path_ast, bound_var, env)
          quote do: {unquote(path), unquote(dir)}

        other ->
          raise ArgumentError,
                "`order_by:` entries must be `asc: var.path` or `desc: var.path`, got " <>
                  "`#{Macro.to_string(other)}`"
      end)

    quote do: ScryCore.Query.order_by(unquote(escaped))
  end

  defp clause_call(:distinct, value_ast, _bound_var, _env) do
    quote do: ScryCore.Query.distinct(unquote(value_ast))
  end

  defp clause_call(:limit, value_ast, _bound_var, _env) do
    quote do: ScryCore.Query.limit(unquote(value_ast))
  end

  defp clause_call(:offset, value_ast, _bound_var, _env) do
    quote do: ScryCore.Query.offset(unquote(value_ast))
  end

  defp clause_call(:select, {:%{}, _, pairs}, bound_var, env) do
    escaped =
      Enum.map(pairs, fn {key, value_ast} ->
        alias_name = select_key!(key)
        expr = Escape.escape_expr(value_ast, bound_var, env)
        quote do: {:computed, unquote(alias_name), unquote(expr)}
      end)

    quote do: ScryCore.Query.select(unquote(escaped))
  end

  defp clause_call(:select, other, _bound_var, _env) do
    raise ArgumentError,
          "`select:` must be a map literal (`%{key: expr, ...}`), got `#{Macro.to_string(other)}` " <>
            "-- a list-shaped select isn't supported yet"
  end

  defp select_key!(key) when is_atom(key), do: to_string(key)

  defp select_key!(other) do
    raise ArgumentError,
          "`select:` map keys must be compile-time atoms, got `#{Macro.to_string(other)}`"
  end
end
