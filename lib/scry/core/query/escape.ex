defmodule Scry.Core.Query.Escape do
  @moduledoc """
  Walks raw, unevaluated Elixir AST (a `where:`/`having:`/`select:`
  clause's own quoted value, from inside `Scry.Core.Query.From`'s macro
  body) and lowers it into `Scry.Core.Query.predicate()`/`expr()`-shaped
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

  **No table-aliasing concept, unlike Ecto** -- Ecto's own arbitrary
  alias (`u`) stands for one of several joined sources, disambiguated
  via a compile-time `vars` list mapping each alias to a positional
  index (`&0`, `&1`, ...). Scry's own language has no table-aliasing
  concept at all: `Scry.Core.Query`'s own moduledoc is explicit that
  correlation resolves by matching a path's leading segment against an
  *ancestor's own literal source name*, at execution time
  (`Scry.Core.Executor`'s own `get_path/3`, matched via `List.keyfind/3`
  against a runtime `scope`), not a parser-time alias. Every function
  below takes a `vars()` map instead of Ecto's own positional list --
  `%{u: :self, o: "orders"}`, say, inside a nested `from o in "orders"`
  under an outer `from u in ..., select: %{orders: from o in ...}}` --
  `:self` means "this query's own bound variable, translate to a bare,
  unqualified path"; a string means "an ancestor's own bound variable,
  translate to a path seeded with its own literal source name" (which
  is why `Scry.Core.Query.From` requires an outer `from`'s own `source`
  to be a compile-time-known string whenever a nested `from` actually
  correlates to it -- there is no other way for *this* module to know
  what literal string to bake into the path, `Scry.Core.Executor`'s own
  scope-threading being fully dynamic notwithstanding). A `var.a.b`
  path whose leading segment doesn't match any name in `vars` is a
  clear compile error listing every name actually in scope, never a
  silent misinterpretation.

  **`^var` is a *named* deferred parameter, not Ecto's own positional
  one** -- `impl_spec.md` §7's own divergence table says the pin is
  meant to carry `$name`'s own role forward exactly ("same injection-
  safety property... for free"), not Ecto's separate value-now/cast-
  later indirection (which Scry doesn't need: a native-builder call
  site already has the pinned value in scope). `^min_age` becomes
  `{:param, "min_age"}` -- the *variable's own written name* -- reusing
  the exact placeholder `Scry.Core.Executor.run/4`'s existing `params`
  argument already resolves. `^` on anything but a bare local variable
  is a clear compile error, matching `$name`'s own bare-identifier-only
  shape in text.

  **`predicate()`'s own `lhs`/`rhs` are narrower than a full `expr()`**
  (`Scry.Core.Query`'s own `@type predicate` -- `lhs :: [String.t()] |
  {:call, ...} | {:dot, ...}`, `rhs :: term() | {:field, ...} |
  {:param, ...}`) -- `escape_predicate/3` respects this rather than
  silently accepting a full `expr()` on either side, which would build
  a query shape `Scry.Core.Executor` was never designed to resolve
  (a confusing *runtime* crash instead of a clear *compile* error).
  Anything wider (e.g. `WHERE price > cost * 1.1`, arithmetic on a
  comparison's own right side) is a real, separate widening of that
  type -- not attempted here; see this module's own catch-all errors.
  """

  @typedoc """
  Maps each bound variable currently in scope to `:self` (this query's
  own bound variable) or its own ancestor's literal source name (a
  `String.t()`) -- see this module's own moduledoc for the full
  reasoning. `Scry.Core.Query.From` builds and threads this.
  """
  @type vars :: %{atom() => :self | String.t()}

  @call_names ~w(
    sum avg count min max stddev_samp stddev_pop var_samp var_pop percentile rate
    string int exact inexact json
    row_number rank first_value last_value
  )

  @doc """
  Escapes `ast` as a `predicate()` -- `where:`/`having:`/a `cond`
  clause's own condition.
  """
  @spec escape_predicate(Macro.t(), vars(), Macro.Env.t()) :: Macro.t()
  def escape_predicate({op, _, [left, right]}, vars, env)
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

    lhs = escape_predicate_lhs(left, vars, env)
    rhs = escape_predicate_rhs(right, vars, env)
    quote do: {:cmp, unquote(cmp_op), unquote(lhs), unquote(rhs)}
  end

  def escape_predicate({:and, _, [left, right]}, vars, env) do
    quote do
      {:and, unquote(escape_predicate(left, vars, env)),
       unquote(escape_predicate(right, vars, env))}
    end
  end

  def escape_predicate({:or, _, [left, right]}, vars, env) do
    quote do
      {:or, unquote(escape_predicate(left, vars, env)),
       unquote(escape_predicate(right, vars, env))}
    end
  end

  def escape_predicate({:not, _, [pred]}, vars, env) do
    quote do: {:not, unquote(escape_predicate(pred, vars, env))}
  end

  def escape_predicate({:in, _, [left, values_ast]}, vars, env) do
    lhs = escape_predicate_lhs(left, vars, env)
    values = escape_in_values(values_ast, vars, env)
    quote do: {:in, unquote(lhs), unquote(values)}
  end

  def escape_predicate(other, _vars, _env) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid predicate -- expected a comparison " <>
            "(==, !=, <, >, <=, >=), `and`/`or`/`not`, or `in`"
  end

  @doc """
  Escapes `ast` as an `expr()` -- `select:`'s own values, an
  arithmetic operand, a `cond` clause's own result. Includes `over/2`
  (window functions, `escape_over/4`'s own comment has the full
  `partition_by:`/`order_by:`/`rows_between:` syntax).
  """
  @spec escape_expr(Macro.t(), vars(), Macro.Env.t()) :: Macro.t()
  def escape_expr({:^, _, [var]}, _vars, _env) do
    quote do: {:param, unquote(pinned_var_name!(var))}
  end

  def escape_expr({{:., _, [_base, field]}, _, []} = ast, vars, _env)
      when is_atom(field) do
    quote do: {:field, unquote(resolve_path!(ast, vars))}
  end

  def escape_expr({op, _, [left, right]}, vars, env)
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
      {:arith, unquote(arith_op), unquote(escape_expr(left, vars, env)),
       unquote(escape_expr(right, vars, env))}
    end
  end

  def escape_expr({:cond, _, [[do: clauses]]}, vars, env) do
    escape_cond(clauses, vars, env)
  end

  def escape_expr({:over, _, [call_ast, opts_ast]}, vars, env) when is_list(opts_ast) do
    escape_over(call_ast, opts_ast, vars, env)
  end

  def escape_expr({name, _, args}, vars, env) when is_atom(name) and is_list(args) do
    escape_call!(name, args, vars, env)
  end

  def escape_expr(literal, _vars, _env)
      when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal) or
             is_atom(literal) do
    literal
  end

  def escape_expr(list, vars, env) when is_list(list) do
    Enum.map(list, &escape_expr(&1, vars, env))
  end

  def escape_expr(other, _vars, _env) do
    raise ArgumentError, "`#{Macro.to_string(other)}` is not a valid Scry expression"
  end

  @doc """
  Escapes `ast` as a bare field path (`group_by:`'s own entries --
  `Scry.Core.Query.group_by/2` expects `[String.t()]`, not a wrapped
  `{:field, ...}` expr()). `order_by:` used to be restricted the same
  way; it now accepts a full `expr()` instead (see
  `escape_order_by_entries/3` below), since lang_spec.md §8.5's own
  `ORDER BY relevance() DESC` needs a call there, not just a field.
  """
  @spec escape_path(Macro.t(), vars(), Macro.Env.t()) :: Macro.t()
  def escape_path(ast, vars, _env), do: resolve_path!(ast, vars)

  @doc """
  Escapes an `order_by:` keyword-list AST (`[asc: u.name, desc: u.age]`
  -- the same `asc:`/`desc:` shorthand `Scry.Core.Query.From`'s own
  `order_by:` clause and `over/2`'s own `order_by:` option both take)
  into the quoted `[{key, :asc | :desc}]` list `Scry.Core.Query.
  order_by/2` expects. Shared by both callers rather than duplicated.
  Each `key` is escaped via `escape_expr/3`, the same as any other
  expression position -- a bare field (`u.name`) becomes `{:field,
  [...]}`, exactly what `Scry.Core.QueryOps`'s own key resolver already
  handles identically to the plain-path shape every caller before this
  widening produced; a call (`relevance()`, an arithmetic expression)
  works the same way for free, no special-casing needed here.
  """
  @spec escape_order_by_entries(Macro.t(), vars(), Macro.Env.t()) :: Macro.t()
  def escape_order_by_entries(entries, vars, env) when is_list(entries) do
    Enum.map(entries, fn
      {dir, key_ast} when dir in [:asc, :desc] ->
        key = escape_expr(key_ast, vars, env)
        quote do: {unquote(key), unquote(dir)}

      other ->
        raise ArgumentError,
              "`order_by:` entries must be `asc: var.path` or `desc: var.path`, got " <>
                "`#{Macro.to_string(other)}`"
    end)
  end

  # ---------------------------------------------------------------------
  # predicate() lhs/rhs -- narrower than a full expr(), see this
  # module's own moduledoc for why.

  defp escape_predicate_lhs({name, _, args}, vars, env)
       when is_atom(name) and is_list(args) do
    escape_call!(name, args, vars, env)
  end

  defp escape_predicate_lhs(ast, vars, _env), do: resolve_path!(ast, vars)

  # Shared by escape_expr/3's own function-call clause and
  # escape_predicate_lhs/3's own -- the exact same recognition + arg-
  # escaping logic either way, `predicate()`'s own `lhs` widening to
  # `{:call, ...}` specifically to let `HAVING sum(total) > 200`
  # (lang_spec §11's own worked example) parse at all.
  defp escape_call!(name, args, vars, env) do
    unless to_string(name) in @call_names do
      raise ArgumentError,
            "`#{name}` is not a recognized Scry function (expected one of: " <>
              "#{Enum.join(@call_names, ", ")})"
    end

    escaped_args = Enum.map(args, &escape_expr(&1, vars, env))
    quote do: {:call, unquote(to_string(name)), unquote(escaped_args)}
  end

  defp escape_predicate_rhs({:^, _, [var]}, _vars, _env) do
    quote do: {:param, unquote(pinned_var_name!(var))}
  end

  defp escape_predicate_rhs({{:., _, [_base, field]}, _, []} = ast, vars, _env)
       when is_atom(field) do
    quote do: {:field, unquote(resolve_path!(ast, vars))}
  end

  defp escape_predicate_rhs({name, _, ctx}, _vars, _env)
       when is_atom(name) and is_atom(ctx) do
    raise ArgumentError,
          "bare variable `#{name}` on a predicate's own right-hand side is ambiguous -- " <>
            "did you mean `^#{name}` (a parameter)?"
  end

  defp escape_predicate_rhs(literal, _vars, _env)
       when is_number(literal) or is_binary(literal) or is_boolean(literal) or is_nil(literal) do
    literal
  end

  defp escape_predicate_rhs(other, _vars, _env) do
    raise ArgumentError,
          "`#{Macro.to_string(other)}` is not a valid predicate right-hand side -- expected a " <>
            "literal, a field path, or a `^pinned` parameter"
  end

  # `in`'s own right-hand side: a bracketed list literal (each element
  # escaped as a predicate-rhs -- a literal or `^param`), or a single
  # field-path/call expr() expected to resolve, as a whole, to the list
  # to check membership against (Scry.Core.Query's own `{:in, lhs,
  # values}` -- `values :: [term() | {:param, ...}] | {:field, ...} |
  # {:call, ...} | {:dot, ...}`).
  defp escape_in_values(list, vars, env) when is_list(list) do
    Enum.map(list, &escape_predicate_rhs(&1, vars, env))
  end

  defp escape_in_values(ast, vars, env), do: escape_expr(ast, vars, env)

  # ---------------------------------------------------------------------
  # cond -> {:when, clauses, else_expr}. lang_spec's own ELSE is
  # mandatory, enforced here at compile time (a non-`true` final clause
  # is a clear error) rather than left to Elixir's own `cond`, which
  # merely crashes at runtime with no matching clause.
  defp escape_cond(clauses, vars, env) do
    {when_clauses, else_clause} = split_cond_clauses!(clauses)

    escaped_when_clauses =
      Enum.map(when_clauses, fn {:->, _, [[pred], expr]} ->
        quote do
          {unquote(escape_predicate(pred, vars, env)), unquote(escape_expr(expr, vars, env))}
        end
      end)

    {:->, _, [[true], else_expr]} = else_clause
    escaped_else = escape_expr(else_expr, vars, env)

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
  # over(call, partition_by: [...], order_by: [...], rows_between: {...})
  # -> {:window, call, partition_by, order_bys, frame}. `over` isn't a
  # real Scry function name (not in @call_names) -- a DSL-level marker
  # this module recognizes specially, the same way `cond` is, since
  # lang_spec's own text syntax (`<call> OVER PARTITION BY ... ORDER BY
  # ... ROWS BETWEEN ... AND ...`) has no natural Elixir infix
  # equivalent to mirror directly. `call` itself is escaped through the
  # ordinary escape_call!/4 -- any of the recognized names, not
  # restricted to the 4 window-only ones or the 11 real aggregates
  # here; `Scry.Core.Executor.compute_window_values/5` is what actually
  # rejects a nonsensical one (`over(string(x), ...)`), the same
  # "grammar/builder stays permissive, execution rejects misuse"
  # posture every other construct in this module already has.
  defp escape_over({name, _, args}, opts, vars, env) when is_atom(name) and is_list(args) do
    call = escape_call!(name, args, vars, env)

    partition_by =
      opts
      |> Keyword.get(:partition_by, [])
      |> Enum.map(&escape_path(&1, vars, env))

    order_bys = escape_order_by_entries(Keyword.get(opts, :order_by, []), vars, env)
    frame = escape_frame!(Keyword.get(opts, :rows_between))

    quote do: {:window, unquote(call), unquote(partition_by), unquote(order_bys), unquote(frame)}
  end

  defp escape_over(other, _opts, _vars, _env) do
    raise ArgumentError,
          "`over/2`'s own first argument must be a recognized call (e.g. `sum(u.total)`, " <>
            "`row_number()`), got `#{Macro.to_string(other)}`"
  end

  defp escape_frame!(nil), do: nil

  defp escape_frame!({start_bound, end_bound}) do
    quote do: {unquote(escape_frame_bound!(start_bound)), unquote(escape_frame_bound!(end_bound))}
  end

  defp escape_frame!(other) do
    raise ArgumentError,
          "`rows_between:` must be a `{start_bound, end_bound}` pair, got `#{inspect(other)}`"
  end

  @frame_bound_atoms [:unbounded_preceding, :current_row, :unbounded_following]

  defp escape_frame_bound!(bound) when bound in @frame_bound_atoms, do: bound

  defp escape_frame_bound!({dir, n})
       when dir in [:preceding, :following] and is_integer(n) and n > 0,
       do: {dir, n}

  defp escape_frame_bound!(other) do
    raise ArgumentError,
          "`#{inspect(other)}` is not a valid frame bound -- expected one of: " <>
            "#{Enum.map_join(@frame_bound_atoms, ", ", &inspect/1)}, `{:preceding, n}`, " <>
            "`{:following, n}` (n a positive integer)"
  end

  # ---------------------------------------------------------------------
  # Shared path resolution -- var.a.b, walked recursively back to
  # whichever bound variable `var` names. Every intermediate segment
  # must itself be a plain zero-arg dot-access (never a call), and the
  # base must be a name present in `vars` -- anything else is a clear
  # "unbound variable" compile error, never silently misread as
  # something else. (Known, accepted imprecision: a genuine zero-arg
  # *module*-qualified call, e.g. `SomeModule.func()`, has the identical
  # AST shape to field access and would hit this same error rather than
  # a more specific one -- v1's 19 recognized call names are all bare,
  # unqualified calls, so this never comes up in practice; not worth
  # the extra complexity to disambiguate for a case that can't
  # currently arise.)
  #
  # `vars[name]` is `:self` (this query's own bound variable -- the
  # resulting path is bare, unqualified) or a `String.t()` (an
  # *ancestor's* own literal source name, seeded as the path's own
  # leading segment -- `Scry.Core.Query.From`'s own moduledoc has the
  # full reasoning for why this has to be a literal string baked in at
  # macro-expansion time, not anything resolved later).
  defp resolve_path!(ast, vars) do
    case collect_path(ast, vars) do
      {:ok, [], var_name} ->
        raise ArgumentError,
              "bare `#{var_name}` isn't a valid field path -- did you mean `#{var_name}.something`?"

      {:ok, segments, _var_name} ->
        segments

      :error ->
        raise ArgumentError,
              "`#{Macro.to_string(ast)}` doesn't resolve to a bound variable in scope -- " <>
                "expected one of: #{vars |> Map.keys() |> Enum.map_join(", ", &"`#{&1}`")}"
    end
  end

  defp collect_path({{:., _, [base, field]}, _, []}, vars) when is_atom(field) do
    case collect_path(base, vars) do
      {:ok, segments, var_name} -> {:ok, segments ++ [Atom.to_string(field)], var_name}
      :error -> :error
    end
  end

  defp collect_path({name, _, ctx}, vars) when is_atom(name) and is_atom(ctx) do
    case Map.fetch(vars, name) do
      {:ok, :self} -> {:ok, [], name}
      {:ok, qualifier} when is_binary(qualifier) -> {:ok, [qualifier], name}
      :error -> :error
    end
  end

  defp collect_path(_other, _vars), do: :error

  defp pinned_var_name!({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: to_string(name)

  defp pinned_var_name!(other) do
    raise ArgumentError,
          "`^#{Macro.to_string(other)}` -- a pin must be a bare local variable (matching " <>
            "text query's own `$name` bare-identifier-only shape), not an expression"
  end
end
