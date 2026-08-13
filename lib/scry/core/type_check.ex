defmodule Scry.Core.TypeCheck do
  @moduledoc """
  The inline half of lang_spec.md §7's compile-time type system: reads
  `type_decls` straight off a parsed `Query.t()`/`CombinedQuery.t()` and
  runs four checks against every query node in the document (walked via
  `Scry.Core.TypeCheck.Nodes.each/2`), no connection or engine involved
  -- the introspection-assisted counterpart that *does* need one lives
  in `Scry.Core.TypeCheck.Introspection`, and layers a merged type-decls
  map on top of this module's own `check/2`.

  **Name-to-source matching.** A `TYPE <name> {...}` attaches to a query
  node iff `<name>` is byte-for-byte identical to that node's own
  single-segment `source` -- the same case-sensitive identifier equality
  already used for fragment names and `WITH` names elsewhere in this
  codebase. A node with no matching `TYPE`, or a multi-segment/absent
  `source`, simply isn't checked here -- an unmatched `TYPE` is not an
  error, mirroring this codebase's existing "unmatched name is just not
  a match" leniency (fragments, `WITH`). Note lang_spec.md's own §7
  worked example (`TYPE User` next to `SELECT users`) doesn't actually
  satisfy this rule as written -- a documentation slip there, not
  evidence against the rule.

  The four checks, each deliberately narrower than lang_spec §7's full
  ambition but real:

  1. **Category check.** A node whose resolved `type_decl.kind` is one
     of the two kinds permanently documented as structurally incapable
     of ever having EP1/EP2 vocabulary (`"relational"`, `"olap"`,
     lang_spec.md §2/§7) but whose own `variant` map is non-empty is a
     hard error. Cannot yet catch a mismatch between two *non-degenerate*
     kinds (e.g. a `graph`-tagged source using time-series' `LAST`) --
     that needs grammar-composition-level metadata this codebase doesn't
     record anywhere yet, and is out of scope this round.
  2. **Declared-field-type / union comparison check.** A literal
     compared against a field with a known declared scalar type
     (currently just `Int`/`String` -- the only two names lang_spec.md
     ever actually specifies) must be accepted by at least one union
     member. An unrecognized type name (another `TYPE`, `JSON`/`DXN`/
     `DXNB`, a generic) is a silent no-op -- existence-checking an
     undeclared field is the adapter's own backend-side job, not this
     layer's.
  3. **`JSON<Type>`/`DXN<Type>`/`DXNB<Type>` field-access validation.**
     An ordinary dot-path into a declared structured field is checked
     against its declared shape (`{:shape, [...]}`); a bare structured
     field (no type parameter, or a `{:list, _}`/unresolved named-type
     parameter) accepts any dot-path with no validation at all, the same
     leniency `JSON` already gets, extended symmetrically to `DXN`/
     `DXNB` (dextrin's text and binary encodings of "the same value
     space" -- the compile-time checker never distinguishes the two
     beyond recognizing both names; decoding either one is an
     execution-layer concern, out of scope here). The explicit
     `json(field)`/`dxn(field)`/`dxnb(field)` escape hatches are never
     validated, matching lang_spec's own stated leniency for `json(...)`.
     Checked against `select`'s own bare field items and `wheres`/
     `havings`' own predicate field references; a field path buried
     inside a computed expression, `GROUP BY`, or `ORDER BY` is not
     walked this round.
  4. **Flow-sensitive compile-time null-safety narrowing.** Mirrors
     `Scry.Core.QueryOps.eval_predicate/4`'s actual runtime short-circuit
     order exactly, not an idealized "was there a nil-check anywhere"
     pattern match: `AND` evaluates left-to-right (a guard must appear
     *before* the comparison it protects -- `age > 30 AND NOT (age =
     nil)` is **not** safe), `OR`'s own short-circuit works the mirror
     way, and `NOT` flips which of its child's two outcomes proves what.
     `HAVING` gets its own independent walk, starting from no proven
     facts -- a `WHERE`-side proof doesn't survive `GROUP BY`. Scoped to
     single-segment declared fields only -- a multi-segment (JSON/DXN/
     DXNB dot-path) field, an aggregate/dot-access `lhs`, or a `{:param,
     ...}` reference on either side of a comparison is treated as
     unprovable and never required to be pre-guarded, not flagged.

  Explicitly out of scope this round (see the approved plan for the
  full reasoning): cross-side type-consistency checking for a
  `CombinedQuery` (lang_spec.md never specifies this as a requirement),
  null-safety narrowing reaching into a structured field's own nested
  nullable markers, and resolving `DXN<Type>`/`DXNB<Type>` against a
  real, externally-registered `.dxns` schema (this round's shapes are
  always inline Scry-level `type_expr()`s, never a named external
  schema).
  """

  alias Scry.Core.{CombinedQuery, Query, TypeCheck.Nodes}

  @degenerate_kinds ["relational", "olap"]
  @structured_type_names ["JSON", "DXN", "DXNB"]
  @known_scalars %{
    "Int" => &is_integer/1,
    "String" => &is_binary/1
  }

  @doc """
  Checks `query_or_combined` against its own `type_decls`. Returns `:ok`
  if every check passes on every query node in the document (including
  nested `select` queries, `with_bindings` values, and both sides of a
  `CombinedQuery`) -- including, trivially, a document with no `TYPE`
  declarations at all, which no check here can ever fire against.
  """
  @spec check(Query.t() | CombinedQuery.t()) :: :ok | {:error, term()}
  def check(%Query{type_decls: type_decls} = query), do: check(query, type_decls)
  def check(%CombinedQuery{type_decls: type_decls} = combined), do: check(combined, type_decls)

  @doc """
  Same as `check/1`, against an explicit `type_decls` map rather than
  whatever is already attached to `query_or_combined` -- the seam
  `Scry.Core.TypeCheck.Introspection` reuses with its own merged map.
  """
  @spec check(Query.t() | CombinedQuery.t(), %{optional(String.t()) => Query.type_decl()}) ::
          :ok | {:error, term()}
  def check(query_or_combined, type_decls) do
    Nodes.each(query_or_combined, &check_node(&1, type_decls))
  end

  defp check_node(%Query{} = query, type_decls) do
    source_name = single_source_name(query.source)
    type_decl = source_name && Map.get(type_decls, source_name)

    with :ok <- category_check(query, type_decl, source_name),
         :ok <- predicate_type_checks(query.wheres, type_decl, source_name),
         :ok <- predicate_type_checks(query.havings, type_decl, source_name),
         :ok <- predicate_json_checks(query.wheres, type_decl),
         :ok <- predicate_json_checks(query.havings, type_decl),
         :ok <- select_field_checks(query.select, type_decl),
         :ok <- null_safety_check(query.wheres, type_decl, source_name),
         :ok <- null_safety_check(query.havings, type_decl, source_name) do
      :ok
    end
  end

  defp single_source_name([name]), do: name
  defp single_source_name(_source), do: nil

  # ---- 1. Category check ---------------------------------------------------

  defp category_check(%Query{variant: variant}, %{kind: kind}, source_name)
       when kind in @degenerate_kinds and map_size(variant) > 0 do
    {:error, {:kind_category_mismatch, source_name, kind, Map.keys(variant)}}
  end

  # `goal_args` (a call-shaped source, lang_spec §8.4's `logic` variant)
  # is plain core grammar, not gated to `logic` at parse time at all
  # (`Scry.Core.Query`'s own moduledoc has the "grammar exists, category
  # check decides legality" reasoning) -- this is where that legality
  # actually gets enforced, the same "degenerate kind + non-empty
  # variant" shape as the clause above, just keyed off a different
  # field. Only checked when a `TYPE` declares a *real, non-nil* `kind`
  # -- `kind: nil` (declared with no `KIND`), or no matching `TYPE` at
  # all, stays silent, the same leniency every other check here already
  # has for an unregistered/untyped source.
  defp category_check(%Query{goal_args: goal_args}, %{kind: kind}, source_name)
       when not is_nil(goal_args) and not is_nil(kind) and kind != "logic" do
    {:error, {:kind_category_mismatch, source_name, kind, [:goal_args]}}
  end

  defp category_check(_query, _type_decl, _source_name), do: :ok

  # ---- 2. Declared-field-type / union comparison check ---------------------

  defp predicate_type_checks(predicates, type_decl, source_name) do
    Enum.reduce_while(predicates, :ok, fn predicate, :ok ->
      case walk_type_check(predicate, type_decl, source_name) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp walk_type_check({:cmp, _op, [name], nil}, _type_decl, _source_name)
       when is_binary(name),
       do: :ok

  defp walk_type_check({:cmp, _op, [name], rhs}, type_decl, source_name)
       when is_binary(name) do
    if literal_rhs?(rhs) do
      check_literal_type(name, rhs, type_decl, source_name)
    else
      :ok
    end
  end

  defp walk_type_check({:cmp, _op, _lhs, _rhs}, _type_decl, _source_name), do: :ok
  defp walk_type_check({:in, _lhs, _values}, _type_decl, _source_name), do: :ok

  defp walk_type_check({:and, l, r}, type_decl, source_name) do
    with :ok <- walk_type_check(l, type_decl, source_name),
         do: walk_type_check(r, type_decl, source_name)
  end

  defp walk_type_check({:or, l, r}, type_decl, source_name) do
    with :ok <- walk_type_check(l, type_decl, source_name),
         do: walk_type_check(r, type_decl, source_name)
  end

  defp walk_type_check({:not, p}, type_decl, source_name),
    do: walk_type_check(p, type_decl, source_name)

  # An unresolved EP1(e) `{:variant, ...}` predicate (e.g. `search`'s
  # own `SEARCH`, `Scry.Core.Query`'s own moduledoc has the full shape)
  # is opaque to core -- no declared-field-type info to check against
  # until the kind's own executor lowers it. `:ok`, not an error: a
  # kind package contributing here is required to fully lower every
  # such leaf before `Scry.Core.Executor.run/3,4` runs (`Scry.Core.
  # EngineBehaviour`'s own contract), but that's a separate, later
  # concern from this compile-time pass, which only ever runs against
  # the raw parsed document.
  defp walk_type_check({:variant, _}, _type_decl, _source_name), do: :ok

  defp literal_rhs?({:field, path}) when is_list(path), do: false
  defp literal_rhs?({:param, name}) when is_binary(name), do: false
  defp literal_rhs?(_other), do: true

  defp check_literal_type(_field, nil, _type_decl, _source_name), do: :ok

  defp check_literal_type(field, literal, type_decl, source_name) do
    case declared_field_type(field, type_decl) do
      nil ->
        :ok

      type_expr ->
        if accepts?(type_expr, literal) do
          :ok
        else
          {:error, {:type_mismatch, source_name, field, type_expr, literal}}
        end
    end
  end

  defp declared_field_type(_field, nil), do: nil

  defp declared_field_type(field, %{fields: fields}) do
    case List.keyfind(fields, field, 0) do
      {_, type_expr} -> type_expr
      nil -> nil
    end
  end

  defp accepts?({:named, name, _param}, literal) do
    case Map.fetch(@known_scalars, name) do
      {:ok, predicate} -> predicate.(literal)
      :error -> true
    end
  end

  defp accepts?({:nullable, inner}, literal), do: is_nil(literal) or accepts?(inner, literal)
  defp accepts?({:union, members}, literal), do: Enum.any?(members, &accepts?(&1, literal))
  defp accepts?({:shape, _fields}, _literal), do: true
  defp accepts?({:list, _inner}, _literal), do: true

  # ---- 3. JSON/DXN/DXNB field-access validation ----------------------------

  defp select_field_checks(items, type_decl) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case select_item_field(item) do
        nil ->
          {:cont, :ok}

        path ->
          case json_path_check(path, type_decl) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
      end
    end)
  end

  defp select_item_field({:field, path}), do: path
  defp select_item_field({:field, path, _param}), do: path
  defp select_item_field(_other), do: nil

  defp predicate_json_checks(predicates, type_decl) do
    Enum.reduce_while(predicates, :ok, fn predicate, :ok ->
      case walk_json_check(predicate, type_decl) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp walk_json_check({:cmp, _op, lhs, rhs}, type_decl) when is_list(lhs) do
    with :ok <- json_path_check(lhs, type_decl) do
      case rhs do
        {:field, path} when is_list(path) -> json_path_check(path, type_decl)
        _other -> :ok
      end
    end
  end

  defp walk_json_check({:cmp, _op, _lhs, _rhs}, _type_decl), do: :ok

  defp walk_json_check({:in, lhs, _values}, type_decl) when is_list(lhs),
    do: json_path_check(lhs, type_decl)

  defp walk_json_check({:in, _lhs, _values}, _type_decl), do: :ok

  defp walk_json_check({:and, l, r}, type_decl) do
    with :ok <- walk_json_check(l, type_decl), do: walk_json_check(r, type_decl)
  end

  defp walk_json_check({:or, l, r}, type_decl) do
    with :ok <- walk_json_check(l, type_decl), do: walk_json_check(r, type_decl)
  end

  defp walk_json_check({:not, p}, type_decl), do: walk_json_check(p, type_decl)

  # Same reasoning as `walk_type_check`'s own `{:variant, ...}` clause
  # above -- opaque to core, no JSON/DXN/DXNB path to validate yet.
  defp walk_json_check({:variant, _}, _type_decl), do: :ok

  defp json_path_check([_single], _type_decl), do: :ok

  defp json_path_check([head | rest], type_decl) do
    case declared_field_type(head, type_decl) do
      nil -> :ok
      type_expr -> check_shape_path(type_expr, rest, head)
    end
  end

  defp check_shape_path(type_expr, path, field_name) do
    case unwrap_structured(type_expr) do
      {:ok, param} -> check_shape_membership(param, path, field_name)
      :not_structured -> :ok
    end
  end

  defp unwrap_structured({:named, name, param}) when name in @structured_type_names,
    do: {:ok, param}

  defp unwrap_structured({:nullable, inner}), do: unwrap_structured(inner)

  defp unwrap_structured({:union, members}) do
    Enum.find_value(members, :not_structured, fn member ->
      case unwrap_structured(member) do
        :not_structured -> nil
        ok -> ok
      end
    end)
  end

  defp unwrap_structured(_other), do: :not_structured

  defp check_shape_membership({:shape, fields}, [next | rest], field_name) do
    case List.keyfind(fields, next, 0) do
      nil ->
        {:error, {:unknown_structured_field, field_name, next}}

      {_, _inner_type} when rest == [] ->
        :ok

      {_, inner_type} ->
        case unwrap_shape_only(inner_type) do
          {:ok, nested_fields} ->
            check_shape_membership({:shape, nested_fields}, rest, field_name)

          :not_shape ->
            :ok
        end
    end
  end

  # bare structured field (no shape param), a `{:list, _}` param, or an
  # unresolved named-type param -- leniency, out of scope this round.
  defp check_shape_membership(_param, _path, _field_name), do: :ok

  defp unwrap_shape_only({:shape, fields}), do: {:ok, fields}
  defp unwrap_shape_only({:nullable, inner}), do: unwrap_shape_only(inner)

  defp unwrap_shape_only({:union, members}) do
    Enum.find_value(members, :not_shape, fn member ->
      case unwrap_shape_only(member) do
        :not_shape -> nil
        ok -> ok
      end
    end)
  end

  defp unwrap_shape_only(_other), do: :not_shape

  # ---- 4. Flow-sensitive null-safety narrowing -----------------------------

  @spec null_safety_check([Query.predicate()], Query.type_decl() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  defp null_safety_check(predicates, type_decl, source_name) do
    predicates
    |> Enum.reduce_while({:ok, MapSet.new()}, fn predicate, {:ok, proven} ->
      case check_predicate(predicate, proven, type_decl, source_name) do
        {:ok, true_facts, _false_facts} -> {:cont, {:ok, true_facts}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _proven} -> :ok
      {:error, _reason} = err -> err
    end
  end

  @spec check_predicate(
          Query.predicate(),
          MapSet.t(),
          Query.type_decl() | nil,
          String.t() | nil
        ) :: {:ok, MapSet.t(), MapSet.t()} | {:error, term()}
  defp check_predicate({:cmp, op, [name], nil}, proven, _type_decl, _source_name)
       when is_binary(name) do
    {true_facts, false_facts} = null_check_facts(op, name)
    {:ok, MapSet.union(proven, true_facts), MapSet.union(proven, false_facts)}
  end

  defp check_predicate({:cmp, _op, _lhs, nil}, proven, _type_decl, _source_name),
    do: {:ok, proven, proven}

  defp check_predicate({:cmp, _op, [name], rhs}, proven, type_decl, source_name)
       when is_binary(name) do
    with :ok <- require_proven(name, proven, type_decl, source_name),
         :ok <- require_proven_rhs(rhs, proven, type_decl, source_name) do
      {:ok, proven, proven}
    end
  end

  defp check_predicate({:cmp, _op, _lhs, _rhs}, proven, _type_decl, _source_name),
    do: {:ok, proven, proven}

  defp check_predicate({:in, _lhs, _values}, proven, _type_decl, _source_name),
    do: {:ok, proven, proven}

  defp check_predicate({:and, l, r}, proven, type_decl, source_name) do
    with {:ok, true_l, _false_l} <- check_predicate(l, proven, type_decl, source_name),
         {:ok, true_r, _false_r} <- check_predicate(r, true_l, type_decl, source_name) do
      {:ok, true_r, proven}
    end
  end

  defp check_predicate({:or, l, r}, proven, type_decl, source_name) do
    with {:ok, _true_l, false_l} <- check_predicate(l, proven, type_decl, source_name),
         {:ok, _true_r, false_r} <- check_predicate(r, false_l, type_decl, source_name) do
      {:ok, proven, false_r}
    end
  end

  defp check_predicate({:not, p}, proven, type_decl, source_name) do
    with {:ok, true_p, false_p} <- check_predicate(p, proven, type_decl, source_name) do
      {:ok, false_p, true_p}
    end
  end

  # Same reasoning as `walk_type_check`'s own `{:variant, ...}` clause
  # above -- opaque to core, proves nothing either way about
  # nullability yet, the same "no-op" treatment the generic `{:cmp, _,
  # _, _}` catch-all above already gets.
  defp check_predicate({:variant, _}, proven, _type_decl, _source_name),
    do: {:ok, proven, proven}

  @spec null_check_facts(:eq | :not_eq | :lt | :gt | :le | :ge | :match, String.t()) ::
          {MapSet.t(), MapSet.t()}
  defp null_check_facts(:eq, name), do: {MapSet.new(), MapSet.new([name])}
  defp null_check_facts(:not_eq, name), do: {MapSet.new([name]), MapSet.new()}
  defp null_check_facts(_other_op, _name), do: {MapSet.new(), MapSet.new()}

  defp require_proven_rhs({:field, [name]}, proven, type_decl, source_name)
       when is_binary(name),
       do: require_proven(name, proven, type_decl, source_name)

  defp require_proven_rhs(_rhs, _proven, _type_decl, _source_name), do: :ok

  defp require_proven(name, proven, type_decl, source_name) do
    case field_status(name, type_decl) do
      :not_declared ->
        :ok

      :non_nullable ->
        :ok

      :nullable ->
        if MapSet.member?(proven, name), do: :ok, else: unguarded_error(source_name, name)
    end
  end

  defp unguarded_error(source_name, name),
    do: {:error, {:unguarded_null_comparison, source_name, name}}

  defp field_status(name, type_decl) do
    case declared_field_type(name, type_decl) do
      nil -> :not_declared
      type_expr -> if nullable?(type_expr), do: :nullable, else: :non_nullable
    end
  end

  defp nullable?({:nullable, _inner}), do: true
  defp nullable?({:union, members}), do: Enum.any?(members, &nullable?/1)
  defp nullable?(_other), do: false
end
