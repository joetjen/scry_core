defmodule ScryCore.Query.Escape do
  @moduledoc """
  Walks raw, unevaluated Elixir AST (a `where:`/`having:`/`select:`
  clause's own quoted value, from inside `ScryCore.Query.From`'s macro
  body) and lowers it into `ScryCore.Query.predicate()`/`expr()`-shaped
  **quoted** tuples -- i.e. every function here returns `Macro.t()`
  (code that, once compiled and run, *evaluates to* a real predicate/
  expr tuple), never an evaluated value itself. Modeled directly on
  `Ecto.Query.Builder.escape/5` (verified against the real source,
  `deps/ecto/lib/ecto/query/builder.ex` in a local Ecto checkout,
  before writing any of this) -- multi-clause pattern match straight on
  raw 3-tuple AST nodes, no `Macro.prewalk`/`postwalk`, no separate
  walker abstraction. One real simplification versus Ecto's own style:
  these functions build results via ordinary `quote do ... unquote(...)
  ... end` blocks rather than Ecto's own manual `{:{}, [], [...]}}`
  tuple-literal construction -- Elixir's own `quote` already produces
  exactly that shape for a 3+-element tuple literal automatically;
  Ecto's manual style exists because its own `escape/5` isn't itself
  running inside a `quote` block the way every function below is
  free to.

  **Single bound variable only, `v1` (see `scry_core`'s own plan/
  changelog for the full reasoning)**: unlike Ecto, which lets an
  arbitrary alias (`u`) stand for one of several joined sources
  (disambiguated via a compile-time `vars` list mapping each alias to
  a positional index), Scry's own language has no table-aliasing
  concept at all -- `ScryCore.Query`'s own moduledoc is explicit that
  correlation resolves by matching a path's leading segment against an
  *ancestor's own literal source name*, at execution time, not parse
  time. A nested `from` (needed to let an inner query's own `where`
  correlate to an outer one, `impl_spec.md` §7's own `select:`-nested-
  `from` example) would need this module to track each ancestor
  binding's real source string, not just its Elixir-side alias --
  genuinely separate work, not implemented here. Every function below
  takes exactly one `bound_var` (the single atom `from var in source`
  bound), and a `var.a.b` path whose leading segment doesn't match it
  is a clear compile error, not a silent misinterpretation.

  **`^var` is a *named* deferred parameter, not Ecto's own positional
  one** -- `impl_spec.md` §7's own divergence table says the pin is
  meant to carry `$name`'s own role forward exactly ("same injection-
  safety property... for free"), not Ecto's separate value-now/cast-
  later indirection (which Scry doesn't need: a native-builder call
  site already has the pinned value in scope). `^min_age` becomes
  `{:param, "min_age"}` -- the *variable's own written name* -- reusing
  the exact placeholder `ScryCore.Executor.run/4`'s existing `params`
  argument already resolves. `^` on anything but a bare local variable
  is a clear compile error, matching `$name`'s own bare-identifier-only
  shape in text.

  **`predicate()`'s own `lhs`/`rhs` are narrower than a full `expr()`**
  (`ScryCore.Query`'s own `@type predicate` -- `lhs :: [String.t()] |
  {:call, ...} | {:dot, ...}`, `rhs :: term() | {:field, ...} |
  {:param, ...}`) -- `escape_predicate/3` respects this rather than
  silently accepting a full `expr()` on either side, which would build
  a query shape `ScryCore.Executor` was never designed to resolve
  (a confusing *runtime* crash instead of a clear *compile* error).
  Anything wider (e.g. `WHERE price > cost * 1.1`, arithmetic on a
  comparison's own right side) is a real, separate widening of that
  type -- not attempted here; see this module's own catch-all errors.
  """

  @call_names ~w(
    sum avg count min max stddev_samp stddev_pop var_samp var_pop percentile
    string int exact inexact json
    row_number rank first_value last_value
  )

  @doc """
  Escapes `ast` as a `predicate()` -- `where:`/`having:`/a `cond`
  clause's own condition.
  """
  @spec escape_predicate(Macro.t(), atom(), Macro.Env.t()) :: Macro.t()
  def escape_predicate({op, _, [left, right]}, bound_var, env)
      when op in [:==, :!=, :<, :>, :<=, :>=] do
    cmp_op =
      case op do
        :== -> :eq
        :!= -> :not_eq
        :< -> :lt
        :> -> :gt
        :<= -> :le
        :>= -> :ge
      end

    lhs = escape_predicate_lhs(left, bound_var, env)
    rhs = escape_predicate_rhs(right, bound_var, env)
    quote do: {:cmp, unquote(cmp_op), unquote(lhs), unquote(rhs)}
  end

  def escape_predicate({:and, _, [left, right]}, bound_var, env) do
    quote do
      {:and, unquote(escape_predicate(left, bound_var, env)),
       unquote(escape_predicate(right, bound_var, env))}
    end
  end

  def escape_predicate({:or, _, [left, right]}, bound_var, env) do
    quote do
      {:or, unquote(escape_predicate(left, bound_var, env)),
       unquote(escape_predicate(right, bound_var, env))}
    end
  end

  def escape_predicate({:not, _, [pred]}, bound_var, env) do
    quote do: {:not, unquote(escape_predicate(pred, bound_var, env))}
  end

  def escape_predicate({:in, _, [left, values_ast]}, bound_var, env) do
    lhs = escape_predicate_lhs(left, bound_var, env)
    values = escape_in_values(values_ast, bound_var, env)
    quote do: {:in, unquote(lhs), unquote(values)}
  end

  def escape_predicate(other, _bound_var, _env) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid predicate -- expected a comparison " <>
            "(==, !=, <, >, <=, >=), `and`/`or`/`not`, or `in`"
  end

  @doc """
  Escapes `ast` as an `expr()` -- `select:`'s own values, an
  arithmetic operand, a `cond` clause's own result.
  """
  @spec escape_expr(Macro.t(), atom(), Macro.Env.t()) :: Macro.t()
  def escape_expr({:^, _, [var]}, _bound_var, _env) do
    quote do: {:param, unquote(pinned_var_name!(var))}
  end

  def escape_expr({{:., _, [_base, field]}, _, []} = ast, bound_var, _env)
      when is_atom(field) do
    quote do: {:field, unquote(resolve_path!(ast, bound_var))}
  end

  def escape_expr({op, _, [left, right]}, bound_var, env)
      when op in [:+, :-, :*, :/, :**] do
    arith_op =
      case op do
        :+ -> :add
        :- -> :sub
        :* -> :mul
        :/ -> :div
        :** -> :pow
      end

    quote do
      {:arith, unquote(arith_op), unquote(escape_expr(left, bound_var, env)),
       unquote(escape_expr(right, bound_var, env))}
    end
  end

  def escape_expr({:cond, _, [[do: clauses]]}, bound_var, env) do
    escape_cond(clauses, bound_var, env)
  end

  def escape_expr({name, _, args}, bound_var, env) when is_atom(name) and is_list(args) do
    escape_call!(name, args, bound_var, env)
  end

  def escape_expr(literal, _bound_var, _env)
      when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal) or
             is_atom(literal) do
    literal
  end

  def escape_expr(list, bound_var, env) when is_list(list) do
    Enum.map(list, &escape_expr(&1, bound_var, env))
  end

  def escape_expr(other, _bound_var, _env) do
    raise ArgumentError, "`#{Macro.to_string(other)}` is not a valid Scry expression"
  end

  @doc """
  Escapes `ast` as a bare field path (`group_by:`/`order_by:`'s own
  entries -- `ScryCore.Query.group_by/2`/`order_by/2` expect
  `[String.t()]`, not a wrapped `{:field, ...}` expr()).
  """
  @spec escape_path(Macro.t(), atom(), Macro.Env.t()) :: Macro.t()
  def escape_path(ast, bound_var, _env), do: resolve_path!(ast, bound_var)

  # ---------------------------------------------------------------------
  # predicate() lhs/rhs -- narrower than a full expr(), see this
  # module's own moduledoc for why.

  defp escape_predicate_lhs({name, _, args}, bound_var, env)
       when is_atom(name) and is_list(args) do
    escape_call!(name, args, bound_var, env)
  end

  defp escape_predicate_lhs(ast, bound_var, _env), do: resolve_path!(ast, bound_var)

  # Shared by escape_expr/3's own function-call clause and
  # escape_predicate_lhs/3's own -- the exact same recognition + arg-
  # escaping logic either way, `predicate()`'s own `lhs` widening to
  # `{:call, ...}` specifically to let `HAVING sum(total) > 200`
  # (lang_spec §11's own worked example) parse at all.
  defp escape_call!(name, args, bound_var, env) do
    unless to_string(name) in @call_names do
      raise ArgumentError,
            "`#{name}` is not a recognized Scry function (expected one of: " <>
              "#{Enum.join(@call_names, ", ")})"
    end

    escaped_args = Enum.map(args, &escape_expr(&1, bound_var, env))
    quote do: {:call, unquote(to_string(name)), unquote(escaped_args)}
  end

  defp escape_predicate_rhs({:^, _, [var]}, _bound_var, _env) do
    quote do: {:param, unquote(pinned_var_name!(var))}
  end

  defp escape_predicate_rhs({{:., _, [_base, field]}, _, []} = ast, bound_var, _env)
       when is_atom(field) do
    quote do: {:field, unquote(resolve_path!(ast, bound_var))}
  end

  defp escape_predicate_rhs({name, _, ctx}, _bound_var, _env)
       when is_atom(name) and is_atom(ctx) do
    raise ArgumentError,
          "bare variable `#{name}` on a predicate's own right-hand side is ambiguous -- " <>
            "did you mean `^#{name}` (a parameter)?"
  end

  defp escape_predicate_rhs(literal, _bound_var, _env)
       when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal) do
    literal
  end

  defp escape_predicate_rhs(other, _bound_var, _env) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid predicate right-hand side -- expected a " <>
            "literal, a field path, or a `^pinned` parameter"
  end

  # `in`'s own right-hand side: a bracketed list literal (each element
  # escaped as a predicate-rhs -- a literal or `^param`), or a single
  # field-path/call expr() expected to resolve, as a whole, to the list
  # to check membership against (ScryCore.Query's own `{:in, lhs,
  # values}` -- `values :: [term() | {:param, ...}] | {:field, ...} |
  # {:call, ...} | {:dot, ...}`).
  defp escape_in_values(list, bound_var, env) when is_list(list) do
    Enum.map(list, &escape_predicate_rhs(&1, bound_var, env))
  end

  defp escape_in_values(ast, bound_var, env), do: escape_expr(ast, bound_var, env)

  # ---------------------------------------------------------------------
  # cond -> {:when, clauses, else_expr}. lang_spec's own ELSE is
  # mandatory, enforced here at compile time (a non-`true` final clause
  # is a clear error) rather than left to Elixir's own `cond`, which
  # merely crashes at runtime with no matching clause.
  defp escape_cond(clauses, bound_var, env) do
    {when_clauses, else_clause} = split_cond_clauses!(clauses)

    escaped_when_clauses =
      Enum.map(when_clauses, fn {:->, _, [[pred], expr]} ->
        quote do
          {unquote(escape_predicate(pred, bound_var, env)),
           unquote(escape_expr(expr, bound_var, env))}
        end
      end)

    {:->, _, [[true], else_expr]} = else_clause
    escaped_else = escape_expr(else_expr, bound_var, env)

    quote do: {:when, unquote(escaped_when_clauses), unquote(escaped_else)}
  end

  defp split_cond_clauses!(clauses) do
    case List.pop_at(clauses, -1) do
      {{:->, _, [[true], _]} = else_clause, when_clauses} when when_clauses != [] ->
        {when_clauses, else_clause}

      _ ->
        raise ArgumentError,
              "a Scry `cond` must end with a `true ->` clause (lang_spec.md's own WHEN...ELSE " <>
                "is mandatory, not optional) preceded by at least one real WHEN clause"
    end
  end

  # ---------------------------------------------------------------------
  # Shared path resolution -- var.a.b, walked recursively back to the
  # bound variable. Every intermediate segment must itself be a plain
  # zero-arg dot-access (never a call), and the base must be exactly
  # `bound_var` -- anything else is a clear "unbound variable" compile
  # error, never silently misread as something else. (Known, accepted
  # imprecision: a genuine zero-arg *module*-qualified call, e.g.
  # `SomeModule.func()`, has the identical AST shape to field access
  # and would hit this same error rather than a more specific one --
  # v1's 19 recognized call names are all bare, unqualified calls, so
  # this never comes up in practice; not worth the extra complexity to
  # disambiguate for a case that can't currently arise.)
  defp resolve_path!(ast, bound_var) do
    case collect_path(ast, bound_var) do
      {:ok, []} ->
        raise ArgumentError,
              "bare `#{bound_var}` isn't a valid field path -- did you mean `#{bound_var}.something`?"

      {:ok, segments} ->
        segments

      :error ->
        raise ArgumentError,
              "`#{Macro.to_string(ast)}` doesn't resolve to the bound variable `#{bound_var}` -- " <>
                "Scry's own native builder supports exactly one bound variable in scope (v1); " <>
                "correlating to an outer query isn't supported yet"
    end
  end

  defp collect_path({{:., _, [base, field]}, _, []}, bound_var) when is_atom(field) do
    case collect_path(base, bound_var) do
      {:ok, segments} -> {:ok, segments ++ [Atom.to_string(field)]}
      :error -> :error
    end
  end

  defp collect_path({name, _, ctx}, bound_var) when name == bound_var and is_atom(ctx) do
    {:ok, []}
  end

  defp collect_path(_other, _bound_var), do: :error

  defp pinned_var_name!({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: to_string(name)

  defp pinned_var_name!(other) do
    raise ArgumentError,
          "`^#{Macro.to_string(other)}` -- a pin must be a bare local variable (matching " <>
            "text query's own `$name` bare-identifier-only shape), not an expression"
  end
end
