defmodule ScryCore.Query.From do
  @moduledoc """
  `ScryCore.Query.from/2`'s own implementation -- kept out of
  `ScryCore.Query` itself so that module's own moduledoc (documenting
  the struct/Layer 1) doesn't have to also carry this macro's own
  keyword-clause dispatch. `ScryCore.Query.from/2` is a one-line
  delegation to `build/4` here (`outer_vars: %{}` for the top-level,
  non-nested call).

  No Ecto-style "try compile-time struct build, fall back to a runtime
  `Module.apply` call" split (`Ecto.Query.Builder.apply_query/4`'s own
  mechanism, confirmed by reading the real source before designing
  this) -- Layer 1's own functions (`ScryCore.Query.new/1`, `where/2`,
  ...) are plain, unconditionally-runtime functions already, so this
  macro always emits one quoted pipeline of Layer 1 calls and lets
  ordinary Elixir compilation handle whether `source` or any escaped
  piece is itself a compile-time literal or a runtime expression --
  no special-casing needed either way.

  **Nested `from`** (a `select:` map value that's itself a `from` call
  -- `impl_spec.md` §7's own worked example, `select: %{orders: from o
  in "orders", where: o.user_id == u.id, ...}}`) recurses into `build/4`
  again, passing this level's own `vars` (`ScryCore.Query.Escape`'s own
  `vars()`) rewritten so *this* level's own bound variable stops being
  `:self` and becomes its own literal source name instead -- exactly
  what a correlated path one level down needs to resolve against. This
  requires the *current* `from`'s own `source` to be a compile-time-
  known string (or list of strings) -- there's no other way to know
  what literal to bake into a correlated path; see `Escape`'s own
  moduledoc for the full reasoning, and `extract_qualifier!/2` below
  for the actual (deliberately lazy -- a dynamic source with no nested
  `from` inside it keeps working exactly as before) check. The nested
  query's own resulting pipeline is spliced into the outer `select`
  list *directly*, not wrapped in `{:computed, ...}` -- `Query.
  body_item()`'s own nested-query shape is `t()` unwrapped, and
  `ScryCore.Executor`'s own `project_item/8` always projects it under
  its own `List.last(source)`, never whatever Elixir map key the
  caller happened to write around it -- checked here at compile time
  (`validate_nested_key!/2`) rather than left to diverge silently.
  """

  alias ScryCore.Query.Escape

  @clause_keys ~w(where having group_by order_by distinct limit offset select)a

  @doc false
  @spec build(Macro.t(), Macro.t(), Escape.vars(), Macro.Env.t()) :: Macro.t()
  def build({:in, _, [var_ast, source_ast]}, opts, outer_vars, env) when is_list(opts) do
    bound_var = bound_var_name!(var_ast)
    vars = Map.put(outer_vars, bound_var, :self)

    unrecognized = Keyword.keys(opts) -- @clause_keys

    unless unrecognized == [] do
      raise ArgumentError,
            "from/2 doesn't recognize #{Enum.map_join(unrecognized, ", ", &"`#{&1}:`")} -- " <>
              "expected one of: #{Enum.map_join(@clause_keys, ", ", &"`#{&1}:`")}"
    end

    base = quote do: ScryCore.Query.new(List.wrap(unquote(source_ast)))

    Enum.reduce(opts, base, fn {key, value_ast}, acc ->
      quote do: unquote(acc) |> unquote(clause_call(key, value_ast, vars, source_ast, env))
    end)
  end

  def build(other, _opts, _outer_vars, _env) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid from/2 header -- expected `var in source`"
  end

  defp bound_var_name!({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name

  defp bound_var_name!(other) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid bound variable -- expected a bare local " <>
            "variable, e.g. `u` in `from u in \"users\"`"
  end

  defp clause_call(:where, value_ast, vars, _source_ast, env) do
    escaped = Escape.escape_predicate(value_ast, vars, env)
    quote do: ScryCore.Query.where(unquote(escaped))
  end

  defp clause_call(:having, value_ast, vars, _source_ast, env) do
    escaped = Escape.escape_predicate(value_ast, vars, env)
    quote do: ScryCore.Query.having(unquote(escaped))
  end

  defp clause_call(:group_by, value_ast, vars, _source_ast, env) when is_list(value_ast) do
    escaped = Enum.map(value_ast, &Escape.escape_path(&1, vars, env))
    quote do: ScryCore.Query.group_by(unquote(escaped))
  end

  defp clause_call(:order_by, value_ast, vars, _source_ast, env) when is_list(value_ast) do
    escaped = Escape.escape_order_by_entries(value_ast, vars, env)
    quote do: ScryCore.Query.order_by(unquote(escaped))
  end

  defp clause_call(:distinct, value_ast, _vars, _source_ast, _env) do
    quote do: ScryCore.Query.distinct(unquote(value_ast))
  end

  defp clause_call(:limit, value_ast, _vars, _source_ast, _env) do
    quote do: ScryCore.Query.limit(unquote(value_ast))
  end

  defp clause_call(:offset, value_ast, _vars, _source_ast, _env) do
    quote do: ScryCore.Query.offset(unquote(value_ast))
  end

  defp clause_call(:select, {:%{}, _, pairs}, vars, source_ast, env) do
    items =
      Enum.map(pairs, fn {key, value_ast} ->
        select_item(key, value_ast, vars, source_ast, env)
      end)

    quote do: ScryCore.Query.select(unquote(items))
  end

  defp clause_call(:select, value_ast, vars, source_ast, env) when is_list(value_ast) do
    items = Enum.map(value_ast, &select_list_item(&1, vars, source_ast, env))
    quote do: ScryCore.Query.select(unquote(items))
  end

  defp clause_call(:select, other, _vars, _source_ast, _env) do
    raise ArgumentError,
          "`select:` must be a map literal (`%{key: expr, ...}`) or a list (`[u.name, " <>
            "total: u.price * u.quantity, ...]`), got `#{Macro.to_string(other)}`"
  end

  # A nested `from` -- spliced directly (t()'s own unwrapped shape),
  # not {:computed, alias, expr}. Recurses with this level's own `vars`
  # rewritten so its own bound variable becomes an ancestor (its own
  # literal source name) rather than :self.
  defp select_item(key, {:from, _, [inner_binding, inner_opts]}, vars, source_ast, env) do
    current_qualifier = extract_qualifier!(source_ast, "a nested `from`")
    validate_nested_key!(key, inner_binding)

    child_vars = rewrite_vars_for_nesting(vars, current_qualifier)
    build(inner_binding, inner_opts, child_vars, env)
  end

  defp select_item(key, value_ast, vars, _source_ast, env) do
    alias_name = select_key!(key)
    expr = Escape.escape_expr(value_ast, vars, env)
    quote do: {:computed, unquote(alias_name), unquote(expr)}
  end

  # A list-shaped `select:`'s own per-item dispatch -- mirrors
  # lang_spec.md §9's own `<body-item> ::= <field> | <alias>: <field> |
  # <alias>: <expression> | ... | nested SELECT`. A bare nested `from`
  # needs no key validation the way the map form's `select_item/5`
  # does above -- there's no map key the caller could have gotten
  # wrong, the output key is unambiguously the nested query's own
  # source name either way.
  defp select_list_item({:from, _, [inner_binding, inner_opts]}, vars, source_ast, env) do
    current_qualifier = extract_qualifier!(source_ast, "a nested `from`")
    child_vars = rewrite_vars_for_nesting(vars, current_qualifier)
    build(inner_binding, inner_opts, child_vars, env)
  end

  # `{key, value_ast}` here is a genuine keyword-pair AST node (`total:
  # u.price * u.quantity` inside a list literal) -- structurally
  # distinct from a dotted field access, which is always a 3-tuple
  # call/dot node, never a bare 2-tuple with a plain atom head.
  defp select_list_item({key, value_ast}, vars, source_ast, env) when is_atom(key) do
    select_item(key, value_ast, vars, source_ast, env)
  end

  defp select_list_item(value_ast, vars, _source_ast, env) do
    path = Escape.escape_path(value_ast, vars, env)
    quote do: {:field, unquote(path)}
  end

  defp rewrite_vars_for_nesting(vars, current_qualifier) do
    Map.new(vars, fn
      {name, :self} -> {name, current_qualifier}
      {name, qualifier} -> {name, qualifier}
    end)
  end

  # `ScryCore.Executor.project_item/8`'s own `{:ok, List.last(nested.
  # source), nested_rows}` always projects a nested query under its own
  # source name, never whatever Elixir map key the caller wrote -- a
  # mismatch would otherwise be a silent, confusing surprise once
  # executed (the caller reads back a totally different key than the
  # one they wrote), so it's a clear compile error instead.
  defp validate_nested_key!(key, {:in, _, [_inner_var, inner_source_ast]}) do
    inner_qualifier = extract_qualifier!(inner_source_ast, "this nested `from`")
    key_name = select_key!(key)

    unless key_name == inner_qualifier do
      raise ArgumentError,
            "`select:` map key `#{key_name}:` doesn't match the nested `from`'s own source " <>
              "(`#{inner_qualifier}`) -- ScryCore.Executor always projects a nested query under " <>
              "its own source name, so write `#{inner_qualifier}: from ... in #{inspect(inner_qualifier)}, ...`"
    end
  end

  defp validate_nested_key!(_key, other) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid from/2 header -- expected `var in source`"
  end

  # A compile-time-known source string (or the last of a list of them)
  # -- see this module's own moduledoc for why nested `from` needs it.
  # `purpose` names what triggered the check, for a clear error.
  defp extract_qualifier!(source_ast, purpose) do
    case extract_qualifier(source_ast) do
      {:ok, qualifier} ->
        qualifier

      :error ->
        raise ArgumentError,
              "#{purpose} needs its own outer `from`'s source to be a compile-time-known " <>
                "string (or list of strings), to know what literal to correlate against -- got " <>
                "`#{Macro.to_string(source_ast)}`"
    end
  end

  defp extract_qualifier(source) when is_binary(source), do: {:ok, source}

  defp extract_qualifier(list) when is_list(list) do
    case List.last(list) do
      last when is_binary(last) -> {:ok, last}
      _ -> :error
    end
  end

  defp extract_qualifier(_other), do: :error

  defp select_key!(key) when is_atom(key), do: to_string(key)

  defp select_key!(other) do
    raise ArgumentError,
          "`select:` map keys must be compile-time atoms, got `#{Macro.to_string(other)}`"
  end
end
