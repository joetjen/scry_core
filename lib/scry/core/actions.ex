defmodule Scry.Core.Actions do
  @moduledoc """
  Turns `priv/grammar.aether`'s parse tree into `%Scry.Core.Query{}` --
  the shared target both Scry front ends converge on (impl_spec.md §7).
  Covers only what that grammar's current Phase 1 subset can produce;
  see its own header for what's deferred.

  Core-only: this module has no idea what a real kind's own EP1(a)/
  EP1(b)/(c)/(d) extension-point rules look like, since none exist yet
  (`scry_time_series` and friends are still just fixture-shaped stands-in
  in `Scry.Core.GrammarComposeTest`). Whatever a loaded fragment's
  `select_ep1a`/`body_item_ep1` evaluates to gets tagged `:variant` and
  left unexamined (`Query.body_item/0`; `query.variant.select_ep1a` for
  the header-modifier position) -- a deliberate stand-in for real
  composed-Actions dispatch (impl_spec.md §4: "Scry's own composed
  Ichor.Actions module is assembled the same way the grammar is"), not
  yet implemented because there is no second real kind to compose
  against yet.

  Two different "is this optional thing absent" conventions are in play
  here, matching the two different capture shapes the grammar's own
  comments document (`priv/grammar.aether`, around `select_ep1a?`):

    - An optional **rule** reference (`select_ep1a?`, `where_clause?`,
      `literal_list?`) produces *no capture key at all* when it doesn't
      match -- checked with `Map.has_key?/2` (`maybe_eval/3` below), not
      by inspecting a value.
    - An optional **token** reference (`neg:KW_NOT?`) always produces a
      capture, evaluating to the literal empty string `""` when absent
      -- checked by value, the ordinary way.

  A third, unrelated wrinkle, found the same way as the two above (by
  running real queries, not by reading Ichor's source): `KW_NIL`/
  `KW_TRUE`/`KW_FALSE` are refiner *targets* (§3 of `priv/grammar.aether`
  -- reclassified from `IDENT`, never declared with their own
  `TOKEN := ...`), and a refiner-target-only name captured from a rule
  produces a bare `{:text, raw_text}` node, not `{:token, name, text}` --
  so `handle_token/3` is never actually invoked for one, no matter what
  clause is written for it. `handle_rule(:literal, ...)` below converts
  these directly instead, dispatching on which single key the alternative
  that matched put in `captures`.
  """

  @behaviour Ichor.Actions

  alias Scry.Core.{Query, Rational}

  @impl true
  def handle_token(:INTEGER, text, _ctx), do: {:ok, String.to_integer(text)}
  def handle_token(:ESCAPED_IDENT, text, _ctx), do: {:ok, String.slice(text, 1..-2//1)}

  # Deliberately *not* a real Elixir atom (`String.to_atom/1`): query
  # text is arbitrary external input, and atoms are never garbage
  # collected on the BEAM -- turning unbounded, attacker-controlled text
  # into new atoms one at a time is a well-known atom-table-exhaustion
  # DoS vector, not a hypothetical one. `{:atom, name}` (a plain binary
  # wrapped in a tuple tag) is exactly as distinguishable from a bare
  # STRING literal for downstream matching purposes, without that risk.
  def handle_token(:ATOM, text, _ctx), do: {:ok, {:atom, String.slice(text, 1..-1//1)}}

  # A placeholder, not a value -- `{:param, name}` carries no more than
  # the name itself at parse time. lang_spec §5.7/§9: resolved against a
  # real value supplied separately at *execution* time
  # (Scry.Core.Executor), never string-interpolated into query text.
  def handle_token(:PARAM, text, _ctx), do: {:ok, {:param, String.slice(text, 1..-1//1)}}

  # Strips the delimiter (either quote char, both one byte -- ASCII `"`
  # or `'`) and resolves escapes over what's left. lang_spec.md §4's own
  # list, exactly: \" \' \\ \n \t \uXXXX -- an unrecognized \<char> was
  # already let through unresolved by priv/grammar.aether's own STRING
  # token (a deliberate leniency, see its comment there), so `unescape/1`
  # only ever needs clauses for the six real escapes plus the two
  # fallthrough cases (an ordinary character, and the empty remainder).
  def handle_token(:STRING, text, _ctx) do
    {:ok, text |> String.slice(1..-2//1) |> unescape()}
  end

  # Same idea, three-character delimiter on each side instead of one --
  # priv/grammar.aether's own MULTILINE_STRING comment has the "why no
  # indentation stripping" reasoning.
  def handle_token(:MULTILINE_STRING, text, _ctx) do
    {:ok, text |> String.slice(3..-4//1) |> unescape()}
  end

  # DATE's own token pattern is lexically permissive (see its comment in
  # priv/grammar.aether) -- real calendar validation happens here, via
  # the stdlib, not in the grammar. Tries the most specific shape (a
  # real offset/"Z") first, then the date+time-with-no-offset form, then
  # falls back to a bare date. A genuinely invalid calendar date (`2026-
  # 02-30`) surfaces as `{:error, reason}` here and propagates through
  # the whole pipeline as an ordinary parse error -- confirmed
  # empirically (scratch grammar) before relying on it, not assumed.
  def handle_token(:DATE, text, _ctx) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} ->
        {:ok, datetime}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, naive_datetime} -> {:ok, naive_datetime}
          {:error, _} -> Date.from_iso8601(text)
        end
    end
  end

  # Any single-byte delimiter now (`Scry.Core.Grammar.SigilLexeme`'s own
  # moduledoc has the "why this needed `@native`" reasoning) -- the
  # delimiter is read from the matched text itself (the byte right after
  # the tag), not assumed to be `/`. `r` is the one concrete tag
  # lang_spec.md §4 actually specifies; any other is a real, reportable
  # error rather than a silent no-op or a guess at unspecified semantics.
  # `Regex.compile/1`'s own `{:error, {message, index}}` is already a
  # valid `handle_token/3` error shape, passed through unchanged -- same
  # "let the stdlib's own error surface as an ordinary parse error"
  # pattern DATE already established.
  def handle_token(
        :SIGIL,
        <<"@", tag::binary-size(1), delim::binary-size(1), rest::binary>>,
        _ctx
      ) do
    content =
      rest
      |> String.slice(0..-2//1)
      |> String.replace("\\" <> delim, delim)

    case tag do
      "r" -> Regex.compile(content)
      other -> {:error, {:unsupported_sigil_tag, other}}
    end
  end

  # "3.14" -> Rational.new(314, 100) -- reduces to 157/50, matching
  # lang_spec.md §4's own worked example exactly, since decimal literals
  # are defined to parse directly to their exact rational value, never
  # an IEEE-754 approximation.
  def handle_token(:DECIMAL, text, _ctx) do
    [whole, fraction] = String.split(text, ".", parts: 2)
    numerator = String.to_integer(whole <> fraction)
    denominator = Integer.pow(10, String.length(fraction))
    {:ok, Rational.new(numerator, denominator)}
  end

  # Radix literals "enter the ordinary exact-rational tower" (lang_spec
  # §4) as plain integers, not a distinct type -- 0x1F is exactly 31.
  def handle_token(:RADIX, <<"0", base_letter::binary-size(1), digits::binary>>, _ctx) do
    base =
      case String.downcase(base_letter) do
        "x" -> 16
        "o" -> 8
        "b" -> 2
      end

    {:ok, String.to_integer(digits, base)}
  end

  # Duration/byte-size literals (lang_spec §4; the exact unit vocabulary
  # -- `priv/grammar.aether`'s own `DURATION`/`BYTE_SIZE` comment has the
  # reasoning) "enter the ordinary exact-rational tower" the same way
  # `RADIX` already does above -- `500ms` is exactly `1/2` (seconds), not
  # a distinct wrapped type. `split_number_and_unit/1` splits on the
  # digit/letter boundary alone (the grammar itself already guarantees
  # the overall shape, so no ambiguity to resolve here); the numeric part
  # reuses `DECIMAL`'s own exact construction when it has a `.`, plain
  # `String.to_integer/1` otherwise.
  def handle_token(:DURATION, text, _ctx) do
    {number, unit} = split_number_and_unit(text)
    {:ok, Rational.mul(parse_exact_number(number), duration_unit_seconds(unit))}
  end

  def handle_token(:BYTE_SIZE, text, _ctx) do
    {number, unit} = split_number_and_unit(text)
    {:ok, Rational.mul(parse_exact_number(number), byte_size_unit_bytes(unit))}
  end

  @impl true
  def handle_rule(:select, captures, ctx) do
    with {:ok, source, ctx} <- captures.source.eval.(ctx),
         {:ok, goal_args, ctx} <- maybe_eval(captures, :goal_args, ctx),
         {:ok, ep1a, ctx} <- maybe_eval(captures, :select_ep1a, ctx),
         {:ok, where_pred, ctx} <- maybe_eval(captures, :where_clause, ctx),
         {:ok, group_by, ctx} <- maybe_eval(captures, :group_by_clause, ctx),
         {:ok, having_pred, ctx} <- maybe_eval(captures, :having_clause, ctx),
         {:ok, distinct, ctx} <- maybe_eval(captures, :distinct_clause, ctx),
         {:ok, order_bys, ctx} <- maybe_eval(captures, :order_by_clause, ctx),
         {:ok, limit_and_offset, ctx} <- maybe_eval(captures, :limit_clause, ctx),
         {:ok, required, ctx} <- maybe_eval(captures, :required_clause, ctx),
         {:ok, select, ctx} <- captures.body.eval.(ctx) do
      variant = if ep1a == :absent, do: %{}, else: %{select_ep1a: ep1a}
      wheres = if where_pred == :absent, do: [], else: [where_pred]
      havings = if having_pred == :absent, do: [], else: [having_pred]
      {limit, offset} = if limit_and_offset == :absent, do: {nil, nil}, else: limit_and_offset
      {group_mode, group_bys} = if group_by == :absent, do: {:plain, []}, else: group_by

      {:ok,
       %Query{
         source: source,
         wheres: wheres,
         group_bys: group_bys,
         group_mode: group_mode,
         havings: havings,
         distinct: distinct != :absent,
         order_bys: absent_to([], order_bys),
         limit: limit,
         offset: offset,
         required: required != :absent,
         select: select,
         variant: variant,
         goal_args: absent_to(nil, goal_args)
       }, ctx}
    end
  end

  # `goal_args := LPAREN call_args? RPAREN` (lang_spec §8.4's call-shaped
  # `logic` source) -- bare `call_args?`, not `args:call_args?`, and
  # `captures.call_args` read the same way `call`'s own handler already
  # does, for the identical reason `priv/grammar.aether`'s own comment
  # on `select_ep1a`/`where_clause` gives: a *renamed* optional rule
  # reference resolves via raw text, not real evaluation. Zero-arity
  # `SELECT ancestor() { ... }` still resolves to `[]`, not `:absent`,
  # matching `call`'s own identical "present but empty" vs "absent
  # entirely" distinction.
  def handle_rule(:goal_args, captures, ctx) do
    with {:ok, args, ctx} <- maybe_eval(captures, :call_args, ctx) do
      {:ok, absent_to([], args), ctx}
    end
  end

  def handle_rule(:path, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  # field_name := IDENT | ESCAPED_IDENT has no clause of its own -- a
  # bare single-token alternative per branch, same single-capture
  # passthrough `comp_op` already relies on, giving `path`'s own `head`/
  # `tail` the right string either way (IDENT's own default text, or
  # ESCAPED_IDENT's delimiter-stripped text above).

  # A nested query -- select's own handler already returns %Query{}
  # directly, so no extra wrapping is needed here (Query.body_item/0).
  def handle_rule(:body_item, %{select: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:body_item, %{body_item_ep1: cap}, ctx) do
    with {:ok, value, ctx} <- cap.eval.(ctx), do: {:ok, {:variant, value}, ctx}
  end

  # field_body_item's own handler already returns the fully-tagged
  # {:field, path} or {:field, path, condition} shape (lang_spec §5.3's
  # IF suffix), so no extra wrapping is needed here either -- same
  # reasoning as select's own clause above.
  def handle_rule(:body_item, %{field_body_item: cap}, ctx), do: cap.eval.(ctx)

  # spread's own handler already returns the fully-tagged {:spread, name}
  # placeholder (lang_spec §5.11/§9) -- same reasoning as every other
  # body_item alternative above, no extra wrapping needed.
  def handle_rule(:body_item, %{spread: cap}, ctx), do: cap.eval.(ctx)

  # `{:spread, name}` -- a placeholder `Scry.Core.FragmentResolver`
  # resolves after `document`'s own handler has both this query's fully
  # -built %Query{} *and* every FRAGMENT declaration's own body list to
  # splice in; see priv/grammar.aether's own `spread` comment for why
  # that can't happen locally, here, the way every other body_item shape
  # resolves itself during this same bottom-up pass.
  def handle_rule(:spread, %{name: name_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx), do: {:ok, {:spread, name}, ctx}
  end

  # A plain `{name, body_items}` pair, not a %Query{} or any other
  # tagged shape -- a FRAGMENT is a reusable *body list*, never executed
  # or projected on its own (lang_spec §9: "reusable shape, vs. `with`'s
  # reusable data"). `document`'s own handler collects every one of
  # these into the name => body_items map Scry.Core.FragmentResolver
  # needs; nothing about a fragment_decl's own shape survives past that.
  def handle_rule(:fragment_decl, %{name: name_cap, body: body_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, body, ctx} <- body_cap.eval.(ctx) do
      {:ok, {name, body}, ctx}
    end
  end

  # `query_cap`'s own handler already returns a real `%Scry.Core.
  # Query{}`/`%Scry.Core.CombinedQuery{}` -- a WITH-bound value is a
  # full query, not a special restricted shape (Scry.Core.Query's own
  # moduledoc), so no extra wrapping is needed here, the same reasoning
  # body_item's own `select` clause already relies on. `recursive_cap`
  # is a bare optional *token* (always produces a capture, empty text
  # when absent), checked by value the same way `combinator_tail`'s own
  # `all:KW_ALL?` already is -- a present `RECURSIVE` marker tags the
  # value `{:recursive, query}` so `Scry.Core.QueryOps.resolve_source/5`/
  # `Scry.Core.WithCycleCheck` can each recognize it without a second
  # `with_bindings` field to keep in sync (`priv/grammar.aether`'s own
  # `with_decl` comment has the fuller reasoning).
  def handle_rule(:with_decl, %{recursive: recursive_cap, name: name_cap, query: query_cap}, ctx) do
    with {:ok, recursive_text, ctx} <- recursive_cap.eval.(ctx),
         {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, query, ctx} <- query_cap.eval.(ctx) do
      value = if recursive_text == "", do: query, else: {:recursive, query}
      {:ok, {name, value}, ctx}
    end
  end

  # `TYPE <name> [: <kind>] { <field>: <type> ... }` (lang_spec §7,
  # priv/grammar.aether's own `type_decl` comment has the full "parsed,
  # not yet consumed" scope reasoning). Returns `{name, type_decl}`, the
  # same `{name, value}` shape `fragment_decl`/`with_decl` above already
  # return -- `document`'s own handler folds every one into a
  # `name => type_decl` map via the same `build_name_map/2` helper.
  def handle_rule(:type_decl, captures, ctx) do
    with {:ok, name, ctx} <- captures.name.eval.(ctx),
         {:ok, kind, ctx} <- maybe_eval(captures, :type_kind, ctx),
         {:ok, fields, ctx} <- captures.fields.eval.(ctx) do
      {:ok, {name, %{name: name, kind: absent_to(nil, kind), fields: fields}}, ctx}
    end
  end

  def handle_rule(:type_kind, %{kind: kind_cap}, ctx), do: kind_cap.eval.(ctx)

  def handle_rule(:type_field_list, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  def handle_rule(:type_field, %{name: name_cap, expr: expr_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, expr, ctx} <- expr_cap.eval.(ctx) do
      {:ok, {name, expr}, ctx}
    end
  end

  # A single operand with no `union_tail` collapses to just that
  # operand's own value, no `{:union, [...]}` wrapper -- see
  # priv/grammar.aether's own `type_expr` comment.
  def handle_rule(:type_expr, %{head: head_cap, union_tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:union_tail, tail_caps, ctx) do
      case tail do
        [] -> {:ok, head, ctx}
        _ -> {:ok, {:union, [head | tail]}, ctx}
      end
    end
  end

  def handle_rule(:union_tail, %{operand: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:type_operand, %{nullable: nullable_cap, base: base_cap}, ctx) do
    with {:ok, nullable_text, ctx} <- nullable_cap.eval.(ctx),
         {:ok, base, ctx} <- base_cap.eval.(ctx) do
      case nullable_text do
        "" -> {:ok, base, ctx}
        _ -> {:ok, {:nullable, base}, ctx}
      end
    end
  end

  # `shape`/`list` (bare rule wrappers, not a bare-passthrough default)
  # and `name` (an `IDENT`, optionally parameterized) are three
  # independently-named `base_type` alternatives -- priv/grammar.aether's
  # own `base_type` comment has the "every alternative gets its own key"
  # reasoning.
  def handle_rule(:base_type, %{shape: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:base_type, %{list: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:base_type, %{name: name_cap} = captures, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, param, ctx} <- maybe_eval(captures, :type_param, ctx) do
      {:ok, {:named, name, absent_to(nil, param)}, ctx}
    end
  end

  def handle_rule(:type_param, %{inner: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:shape_type, %{fields: cap}, ctx) do
    with {:ok, fields, ctx} <- cap.eval.(ctx), do: {:ok, {:shape, fields}, ctx}
  end

  def handle_rule(:list_type, %{inner: cap}, ctx) do
    with {:ok, inner, ctx} <- cap.eval.(ctx), do: {:ok, {:list, inner}, ctx}
  end

  # `combined_select`'s own handler already returns either a real
  # %Scry.Core.Query{} (no combinator used) or a %Scry.Core.CombinedQuery{}
  # (one or more used) -- no extra wrapping needed here, the same
  # reasoning body_item's own `select` clause already relies on.
  def handle_rule(:combined_select, %{head: head_cap, combinator_tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tails, ctx} <- eval_list(:combinator_tail, tail_caps, ctx) do
      {:ok, fold_combinators(head, tails), ctx}
    end
  end

  # Returns its own `{op, right}` piece, not a folded `%CombinedQuery{}`
  # -- `combinator_tail` has no idea what `head`/the running accumulator
  # is, only `combined_select`'s own handler (`fold_combinators/2`)
  # does, the exact same left-to-right fold shape `expression`'s own
  # `additive_tail` already uses for `+`/`-` chains.
  def handle_rule(:combinator_tail, %{union: _union_cap, all: all_cap, right: right_cap}, ctx) do
    with {:ok, all_text, ctx} <- all_cap.eval.(ctx),
         {:ok, right, ctx} <- right_cap.eval.(ctx) do
      op = if all_text == "", do: :union, else: :union_all
      {:ok, {op, right}, ctx}
    end
  end

  def handle_rule(:combinator_tail, %{intersect: _intersect_cap, right: right_cap}, ctx) do
    with {:ok, right, ctx} <- right_cap.eval.(ctx), do: {:ok, {:intersect, right}, ctx}
  end

  def handle_rule(:combinator_tail, %{except: _except_cap, right: right_cap}, ctx) do
    with {:ok, right, ctx} <- right_cap.eval.(ctx), do: {:ok, {:except, right}, ctx}
  end

  # The real root (priv/grammar.aether's own `@root document`/`document`
  # comments have the full reasoning). `type_or_comment`/
  # `fragment_or_comment`/`with_or_comment` are all bare/unrenamed and
  # `*`-repeated, so each always has its own key -- `[]`, not a missing
  # one, when absent (confirmed empirically, same finding as
  # `additive_tail`/`when_clause` elsewhere in this module), so no
  # `maybe_eval` is needed here the way an *optional* rule reference
  # would need. Each list is filtered down to just the real
  # declarations (`is_tuple/1` -- a real one is always `{name, value}`;
  # a matched `BLOCK_COMMENT` inside one of these wrapper rules is a
  # bare token string, its own default passthrough) before building the
  # name map -- priv/grammar.aether's own `document` comment has the
  # full "why a comment and a real declaration are mutually exclusive
  # alternatives at the same position" reasoning.
  #
  # Duplicate `TYPE`/`FRAGMENT`/`WITH` names are each a real, reportable
  # compile error (`Map.new/2` would otherwise silently let the second
  # declaration win) -- checked before handing any map onward, which
  # assumes it's already unambiguous. `Scry.Core.WithCycleCheck` runs
  # after the map is built but doesn't need the final query at all (a
  # cycle is a property of the bindings alone) -- ordered before
  # `FragmentResolver` for no real reason beyond it being the cheaper,
  # `select`-independent check to fail on first. `type_decls` needs no
  # analogous cycle check -- a `TYPE`'s own fields reference other type
  # names only as *data shape* descriptions, never as something
  # `Scry.Core.Executor` would ever recurse into evaluating (unlike a
  # `WITH` binding's own `source`, which genuinely can recurse at
  # execution time).
  #
  # `select_cap` (really `combined_select`, renamed -- see
  # priv/grammar.aether's own `document` comment) may itself evaluate to
  # either a %Query{} or a %CombinedQuery{} -- `Scry.Core.FragmentResolver
  # .resolve/2` already dispatches on both (its own moduledoc), and
  # `with_bindings`/`type_decls` both attach to whichever type comes
  # back, since either can legitimately be the top-level result of a
  # document.
  def handle_rule(
        :document,
        %{
          type_or_comment: type_caps,
          fragment_or_comment: frag_caps,
          with_or_comment: with_caps,
          select: select_cap
        },
        ctx
      ) do
    with {:ok, type_items, ctx} <- eval_list(:type_or_comment, type_caps, ctx),
         {:ok, type_decls} <-
           build_name_map(Enum.filter(type_items, &is_tuple/1), :duplicate_type),
         {:ok, frag_items, ctx} <- eval_list(:fragment_or_comment, frag_caps, ctx),
         {:ok, fragments} <-
           build_name_map(Enum.filter(frag_items, &is_tuple/1), :duplicate_fragment),
         {:ok, with_items, ctx} <- eval_list(:with_or_comment, with_caps, ctx),
         {:ok, with_bindings} <-
           build_name_map(Enum.filter(with_items, &is_tuple/1), :duplicate_with),
         :ok <- Scry.Core.WithCycleCheck.check(with_bindings),
         {:ok, result, ctx} <- select_cap.eval.(ctx) do
      case Scry.Core.FragmentResolver.resolve(result, fragments) do
        {:ok, %Query{} = resolved} ->
          finalize_document(
            %Query{resolved | with_bindings: with_bindings, type_decls: type_decls},
            ctx
          )

        {:ok, %Scry.Core.CombinedQuery{} = resolved} ->
          finalize_document(
            %Scry.Core.CombinedQuery{
              resolved
              | with_bindings: with_bindings,
                type_decls: type_decls
            },
            ctx
          )

        {:error, _} = err ->
          err
      end
    end
  end

  def handle_rule(:field_body_item, %{alias: alias_cap, expr: expr_cap} = captures, ctx) do
    with {:ok, alias_name, ctx} <- alias_cap.eval.(ctx),
         {:ok, expr, ctx} <- expr_cap.eval.(ctx),
         {:ok, scoping_where, ctx} <- maybe_eval(captures, :where_clause, ctx) do
      case scoping_where do
        :absent -> {:ok, {:computed, alias_name, expr}, ctx}
        predicate -> {:ok, {:computed, alias_name, expr, predicate}, ctx}
      end
    end
  end

  def handle_rule(:field_body_item, %{field: field_cap} = captures, ctx) do
    with {:ok, path, ctx} <- field_cap.eval.(ctx),
         {:ok, condition, ctx} <- maybe_eval(captures, :if_clause, ctx) do
      case condition do
        :absent -> {:ok, {:field, path}, ctx}
        param -> {:ok, {:field, path, param}, ctx}
      end
    end
  end

  # if_clause's own value is just whatever PARAM already produced
  # ({:param, name}, via handle_token(:PARAM, ...)) -- KW_IF itself
  # carries no information worth keeping, so this exists only to pick
  # `param` out from between the two captures (single-capture
  # passthrough doesn't apply here, since there are two).
  def handle_rule(:if_clause, %{param: param_cap}, ctx), do: param_cap.eval.(ctx)

  # `bitwise_tail`/`additive_tail`/`mult_tail` (all `*`-repeated) always
  # produce their own key, an empty list when there were zero
  # repetitions -- unlike a `?`-optional *rule* reference, which
  # produces no key at all when absent (confirmed empirically, priv/
  # grammar.aether's own `power` comment has the fuller story). No
  # `maybe_eval`/absence check needed here because of that: `eval_list`
  # already handles "zero or more" uniformly, the same helper `path`'s
  # own `tail` already relies on.
  def handle_rule(:expression, %{left: left_cap, bitwise_tail: tail_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, tails, ctx} <- eval_list(:bitwise_tail, tail_caps, ctx) do
      {:ok, fold_bitwise(left, tails), ctx}
    end
  end

  # Returns its own `{op, right}` piece, not a folded `{:bitwise, ...}`
  # tuple -- `bitwise_tail` has no idea what `left`/the running
  # accumulator is, only `expression`'s own handler (`fold_bitwise/2`)
  # does, the same left-to-right fold shape `additive_tail`'s own
  # `fold_arith/2` already uses one tier down.
  def handle_rule(:bitwise_tail, %{op: op_cap, right: right_cap}, ctx) do
    with {:ok, op_text, ctx} <- op_cap.eval.(ctx),
         {:ok, right, ctx} <- right_cap.eval.(ctx) do
      {:ok, {bitwise_op_from_text(op_text), right}, ctx}
    end
  end

  # `additive` -- one precedence tier down from `expression`/`bitwise_tail`
  # above (renamed from this module's own former `:expression` clause,
  # priv/grammar.aether's own comment on the arithmetic/bitwise chain has
  # the full "why `additive` now, not `expression`" reasoning; body
  # unchanged).
  def handle_rule(:additive, %{left: left_cap, additive_tail: tail_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, tails, ctx} <- eval_list(:additive_tail, tail_caps, ctx) do
      {:ok, fold_arith(left, tails), ctx}
    end
  end

  # Returns its own `{op, right}` piece, not a folded `{:arith, ...}`
  # tuple -- `additive_tail` has no idea what `left`/the running
  # accumulator is, only `additive`'s own handler (`fold_arith/2`)
  # does, the same left-to-right fold shape `eval_chain/5` already uses
  # for `disjunction`/`conjunction`, just carrying its own operator per
  # repetition instead of one fixed one.
  def handle_rule(:additive_tail, %{op: op_cap, right: right_cap}, ctx) do
    with {:ok, op_text, ctx} <- op_cap.eval.(ctx),
         {:ok, right, ctx} <- right_cap.eval.(ctx) do
      {:ok, {arith_op_from_text(op_text), right}, ctx}
    end
  end

  def handle_rule(:multiplicative, %{left: left_cap, mult_tail: tail_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, tails, ctx} <- eval_list(:mult_tail, tail_caps, ctx) do
      {:ok, fold_arith(left, tails), ctx}
    end
  end

  def handle_rule(:mult_tail, %{op: op_cap, right: right_cap}, ctx) do
    with {:ok, op_text, ctx} <- op_cap.eval.(ctx),
         {:ok, right, ctx} <- right_cap.eval.(ctx) do
      {:ok, {arith_op_from_text(op_text), right}, ctx}
    end
  end

  # `predicate_lhs`'s own three arithmetic/bitwise alternatives
  # (`priv/grammar.aether`'s own comment on `bitwise_lhs`/`additive_lhs`/
  # `mult_lhs` has the full "why three tiers, not one `expression`
  # reference" reasoning) -- each folds `[head | rest]` onto `left` via
  # the exact same `fold_bitwise`/`fold_arith` helpers `:expression`/
  # `:additive`/`:multiplicative` already use above, just seeded from a
  # `head` + `rest` pair (always at least one tail) instead of a
  # possibly-empty `*`-repeated list.
  def handle_rule(:bitwise_lhs, %{left: left_cap, head: head_cap, rest: rest_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, rest, ctx} <- eval_list(:rest, rest_caps, ctx) do
      {:ok, fold_bitwise(left, [head | rest]), ctx}
    end
  end

  def handle_rule(:additive_lhs, %{left: left_cap, head: head_cap, rest: rest_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, rest, ctx} <- eval_list(:rest, rest_caps, ctx) do
      {:ok, fold_arith(left, [head | rest]), ctx}
    end
  end

  def handle_rule(:mult_lhs, %{left: left_cap, head: head_cap, rest: rest_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, rest, ctx} <- eval_list(:rest, rest_caps, ctx) do
      {:ok, fold_arith(left, [head | rest]), ctx}
    end
  end

  # `exp` present vs. absent are two genuinely different capture sets
  # (`%{base:, exp:}` vs. just `%{base:}`), the same clause-order
  # disambiguation `comparison`'s own alternatives already use below --
  # not `maybe_eval`, since there's nothing else in this rule's own
  # captures to fall back on if it were absent.
  def handle_rule(:power, %{base: base_cap, exp: exp_cap}, ctx) do
    with {:ok, base, ctx} <- base_cap.eval.(ctx),
         {:ok, exponent, ctx} <- exp_cap.eval.(ctx) do
      {:ok, {:arith, :pow, base, exponent}, ctx}
    end
  end

  def handle_rule(:power, %{base: base_cap}, ctx), do: base_cap.eval.(ctx)

  # Unary bitwise-NOT (`!`)/unary minus (`-`), lang_spec §5's own
  # precedence-table tier 1 -- `op`/`operand` present vs. absent are two
  # genuinely different capture sets (`%{op:, operand:}` vs. the bare
  # `%{primary: cap}` passthrough just below), the same clause-order
  # disambiguation `power`'s own two clauses just above already use.
  def handle_rule(:unary, %{op: op_cap, operand: operand_cap}, ctx) do
    with {:ok, op_text, ctx} <- op_cap.eval.(ctx),
         {:ok, operand, ctx} <- operand_cap.eval.(ctx) do
      {:ok, {:unary, unary_op_from_text(op_text), operand}, ctx}
    end
  end

  def handle_rule(:unary, %{primary: cap}, ctx), do: cap.eval.(ctx)

  # `literal`'s own resolved value flows straight into the expression
  # AST unchanged (a plain value, or already one of `expr()`'s own
  # placeholder tags like `{:param, name}` -- ATOM/PARAM's own
  # handle_token clauses already produce exactly these). `path` gets
  # wrapped `{:field, path}` here, the same tag a comparison's own
  # right-hand side already uses for the identical concept (path naming
  # a field, to be resolved against a row at execution time).
  def handle_rule(:primary, %{literal: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:primary, %{path: cap}, ctx) do
    with {:ok, path, ctx} <- cap.eval.(ctx), do: {:ok, {:field, path}, ctx}
  end

  def handle_rule(:primary, %{when_expr: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:primary, %{inner: cap}, ctx), do: cap.eval.(ctx)

  # call's own handler already returns the fully-tagged {:call, name,
  # args} shape -- same reasoning as when_expr/inner above.
  def handle_rule(:primary, %{call: cap}, ctx), do: cap.eval.(ctx)

  # call_with_path's own handler already returns the fully-tagged {:dot,
  # base, path} shape -- same reasoning as call's own clause just above.
  def handle_rule(:primary, %{call_with_path: cap}, ctx), do: cap.eval.(ctx)

  # lang_spec §5.8's built-in functions (sum/avg/count/min/max/etc,
  # this phase's real set) -- Scry.Core.QueryOps.eval_aggregate/6 decides
  # which `name`s it actually knows how to run, not this module (same
  # split as body_item_ep1's own {:variant, value}, a construct the
  # grammar accepts generally that only *some* of the pipeline
  # ultimately executes). `call_args` is optional now (window
  # functions' own `row_number()`/`rank()`, priv/grammar.aether's own
  # `call` comment) -- read the same way `list`'s own handler already
  # reads `:literal_list` (`maybe_eval/3`, absent -> `[]`), not a
  # renamed `args` key (there isn't one anymore -- see that same
  # comment for why).
  def handle_rule(:call, %{name: name_cap} = captures, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, args, ctx} <- maybe_eval(captures, :call_args, ctx) do
      {:ok, {:call, name, absent_to([], args)}, ctx}
    end
  end

  # EP2 namespaced call (lang_spec §2, `priv/grammar.aether`'s own
  # `qualified_call` comment has the full "why this needs its own rule,
  # not a renaming of `call_with_path`" reasoning). Folds `namespace`/
  # `name` into the identical `{:call, "namespace.name", args}` shape a
  # plain `call` already produces, joined with a literal `.` -- the
  # same string an *unqualified*, auto-imported spelling would resolve
  # to once auto-import resolution is real (impl_spec.md §4's own "core
  # built-ins first, then each loaded kind's own auto-imported names"),
  # so a future auto-import pass has exactly one string shape to
  # recognize either way, not two.
  def handle_rule(
        :qualified_call,
        %{namespace: namespace_cap, name: name_cap} = captures,
        ctx
      ) do
    with {:ok, namespace, ctx} <- namespace_cap.eval.(ctx),
         {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, args, ctx} <- maybe_eval(captures, :call_args, ctx) do
      {:ok, {:call, "#{namespace}.#{name}", absent_to([], args)}, ctx}
    end
  end

  # `ns.lookup(id).status` -- the qualified-call counterpart to `call_
  # with_path`'s own handler just below (`json(metadata).color`),
  # identical shape, different base.
  def handle_rule(:qualified_call_with_path, %{call: call_cap, path: path_cap}, ctx) do
    with {:ok, call, ctx} <- call_cap.eval.(ctx),
         {:ok, path, ctx} <- path_cap.eval.(ctx) do
      {:ok, {:dot, call, path}, ctx}
    end
  end

  def handle_rule(:call_args, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  # `json(<field>).path...` (lang_spec §5.8/§7) -- `call`'s own handler
  # already returns the fully-tagged `{:call, name, args}` shape, so this
  # just wraps it with the trailing path, the same `{:field, path}`
  # already wraps a bare `path` for the identical concept (a path naming
  # where to look, resolved against a value at execution time -- a row
  # for `{:field, ...}`, this call's own result for `{:dot, ...}`).
  def handle_rule(:call_with_path, %{call: call_cap, path: path_cap}, ctx) do
    with {:ok, call, ctx} <- call_cap.eval.(ctx),
         {:ok, path, ctx} <- path_cap.eval.(ctx) do
      {:ok, {:dot, call, path}, ctx}
    end
  end

  # `count(distinct …)` (lang_spec §5.8) -- `call_arg`'s own second
  # alternative (bare `expression`, no `DISTINCT`) needs no clause here
  # at all, the same default single-capture passthrough `field_name :=
  # IDENT | ESCAPED_IDENT` already relies on; only the `DISTINCT`-
  # prefixed shape needs wrapping.
  def handle_rule(:call_arg, %{distinct: _distinct_cap, expr: expr_cap}, ctx) do
    with {:ok, expr, ctx} <- expr_cap.eval.(ctx), do: {:ok, {:distinct, expr}, ctx}
  end

  # Window functions (lang_spec §5.5, priv/grammar.aether's own
  # `window_call`/`over_spec` comments). `call`'s own handler above
  # already returns the fully-tagged `{:call, name, args}` shape.
  def handle_rule(:window_call, %{call: call_cap, over: over_cap}, ctx) do
    with {:ok, call, ctx} <- call_cap.eval.(ctx),
         {:ok, {partition_by, order_bys, frame}, ctx} <- over_cap.eval.(ctx) do
      {:ok, {:window, call, partition_by, order_bys, frame}, ctx}
    end
  end

  # All three pieces independently optional (priv/grammar.aether's own
  # `over_spec` comment) -- absent partition/order default to `[]`
  # (`Query.t()`'s own `group_bys`/`order_bys` fields use the same
  # "empty list means unpartitioned/unordered" convention already),
  # absent frame to `nil` (`Scry.Core.Executor`'s own frame-resolution
  # comment: "default = whole partition").
  def handle_rule(:over_spec, captures, ctx) do
    with {:ok, partition_by, ctx} <- maybe_eval(captures, :partition_clause, ctx),
         {:ok, order_bys, ctx} <- maybe_eval(captures, :order_by_clause, ctx),
         {:ok, frame, ctx} <- maybe_eval(captures, :frame_clause, ctx) do
      {:ok, {absent_to([], partition_by), absent_to([], order_bys), absent_to(nil, frame)}, ctx}
    end
  end

  # Same shape as `group_by_clause`'s own handler above -- both just
  # reuse `field_list` directly.
  def handle_rule(:partition_clause, %{fields: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:frame_clause, %{start: start_cap, stop: stop_cap}, ctx) do
    with {:ok, start, ctx} <- start_cap.eval.(ctx),
         {:ok, stop, ctx} <- stop_cap.eval.(ctx) do
      {:ok, {start, stop}, ctx}
    end
  end

  # Three clauses, one per `frame_bound` grammar alternative -- the
  # `n:INTEGER`-carrying one declared *before* the `UNBOUNDED`-only one
  # since both share the `prec_or_foll` capture key and Elixir's own
  # map-pattern matching would otherwise let the narrower pattern match
  # the `n`-carrying captures too (extra keys in the map don't prevent
  # a narrower pattern from matching -- ordering is what disambiguates
  # here, most-specific first, the same discipline this module already
  # follows for `comparison`'s own alternatives).
  def handle_rule(:frame_bound, %{n: n_cap, prec_or_foll: pf_cap}, ctx) do
    with {:ok, n, ctx} <- n_cap.eval.(ctx),
         {:ok, pf_text, ctx} <- pf_cap.eval.(ctx) do
      {:ok, {frame_bound_tag(pf_text, :preceding, :following), n}, ctx}
    end
  end

  def handle_rule(:frame_bound, %{prec_or_foll: pf_cap}, ctx) do
    with {:ok, pf_text, ctx} <- pf_cap.eval.(ctx) do
      {:ok, frame_bound_tag(pf_text, :unbounded_preceding, :unbounded_following), ctx}
    end
  end

  # `KW_CURRENT KW_ROW` has no named captures at all -- the third
  # `frame_bound` alternative, unambiguous once the two clauses above
  # (both requiring `prec_or_foll`) don't match.
  def handle_rule(:frame_bound, _captures, ctx), do: {:ok, :current_row, ctx}

  # `when_clause` (`+`-repeated) always produces at least one element --
  # the grammar itself enforces "at least one WHEN...THEN", not a check
  # here (priv/grammar.aether's own `when_expr` comment). No absence
  # check needed for the same reason `additive_tail`/`mult_tail` don't
  # need one either.
  def handle_rule(:when_expr, %{when_clause: clause_caps, else_expr: else_cap}, ctx) do
    with {:ok, clauses, ctx} <- eval_list(:when_clause, clause_caps, ctx),
         {:ok, else_expr, ctx} <- else_cap.eval.(ctx) do
      {:ok, {:when, clauses, else_expr}, ctx}
    end
  end

  # Returns its own `{predicate, then_expr}` pair -- `Scry.Core.Executor`
  # walks the list in order and reuses `eval_predicate/4` (the exact
  # function a `where` clause's own predicates already go through)
  # directly on each one, rather than this module trying to fold
  # anything itself; there's no accumulator to fold into here the way
  # `additive_tail`'s own `{op, right}` pairs get folded by `expression`.
  def handle_rule(:when_clause, %{cond: cond_cap, then_expr: then_cap}, ctx) do
    with {:ok, predicate, ctx} <- cond_cap.eval.(ctx),
         {:ok, then_expr, ctx} <- then_cap.eval.(ctx) do
      {:ok, {predicate, then_expr}, ctx}
    end
  end

  def handle_rule(:body_list, %{head: head_cap, body_list_tail: tail_cap}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- tail_cap.eval.(ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  # `body_list_tail := (~body_list_sep tail:body_item ~body_list_tail)?`
  # (priv/grammar.aether's own comment there has the full "why
  # right-recursion" reasoning) -- an unmatched `?` group evaluates via
  # `Ichor.Actions`' default fallback to a `%Ichor.Node{captures: %{}}`
  # for an *empty* capture map (confirmed via scratch grammar, not
  # assumed), never `nil`/`[]` directly, so this clause matches on the
  # empty map itself, not on an absent key. The matched-something clause
  # below evaluates `body_list_sep` purely to force its own
  # same-line-vs-newline validation to run (its `:ok` value is
  # otherwise discarded) -- `with`'s short-circuit is what turns a
  # `body_list_sep` validation failure into this whole chain's error,
  # exactly like every other error in this pipeline.
  def handle_rule(:body_list_tail, captures, ctx) when map_size(captures) == 0,
    do: {:ok, [], ctx}

  def handle_rule(
        :body_list_tail,
        %{body_list_sep: sep_cap, tail: tail_cap, body_list_tail: rest_cap},
        ctx
      ) do
    with {:ok, _sep, ctx} <- sep_cap.eval.(ctx),
         {:ok, tail, ctx} <- tail_cap.eval.(ctx),
         {:ok, rest, ctx} <- rest_cap.eval.(ctx) do
      {:ok, [tail | rest], ctx}
    end
  end

  # lang_spec §6: comma required when two items share a physical line,
  # optional (a line break suffices) when each is on its own line.
  # `status` is `Scry.Core.Grammar.BodyListSep.match/4`'s own
  # classification ("ok"/"missing_comma") of a forward+backward token
  # stream scan (that module's own moduledoc has the full "why not
  # ordinary grammar composition" story) -- this handler's only job is
  # turning that into a real `{:error, ...}` when the answer was no.
  # `Ichor.Error.new/1`'s `stage: :action` is the intended tag for a
  # validation failure raised from inside a `handle_rule` callback
  # rather than from parsing/lexing itself.
  def handle_rule(:body_list_sep, %{status: status_cap}, ctx) do
    with {:ok, status, ctx} <- status_cap.eval.(ctx) do
      if status == "ok" do
        {:ok, :ok, ctx}
      else
        {:error,
         Ichor.Error.new(
           message:
             "comma required between two body items on the same physical line (lang_spec.md §6)",
           stage: :action
         )}
      end
    end
  end

  def handle_rule(:where_clause, %{cond: cond_cap}, ctx), do: cond_cap.eval.(ctx)

  # `group_by_clause`'s own three alternatives (lang_spec §5.2) each
  # tag their result `{:plain | :rollup | :cube, fields}` -- `select`'s
  # own handler below destructures this into `Query.t()`'s separate
  # `group_bys`/`group_mode` fields. `group_by_rollup`/`group_by_cube`
  # do the actual tagging (their own clauses further down); the plain
  # `fields:field_list` fallback tags here since it has no rule of its
  # own to do it in.
  def handle_rule(:group_by_clause, %{group_by_rollup: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:group_by_clause, %{group_by_cube: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:group_by_clause, %{fields: cap}, ctx) do
    with {:ok, fields, ctx} <- cap.eval.(ctx), do: {:ok, {:plain, fields}, ctx}
  end

  def handle_rule(:group_by_rollup, %{fields: cap}, ctx) do
    with {:ok, fields, ctx} <- cap.eval.(ctx), do: {:ok, {:rollup, fields}, ctx}
  end

  def handle_rule(:group_by_cube, %{fields: cap}, ctx) do
    with {:ok, fields, ctx} <- cap.eval.(ctx), do: {:ok, {:cube, fields}, ctx}
  end

  def handle_rule(:having_clause, %{cond: cond_cap}, ctx), do: cond_cap.eval.(ctx)

  # distinct_clause := KW_DISTINCT has no named capture -- `select`'s
  # own handling only ever checks *presence* (maybe_eval/:absent), so
  # the default single-capture passthrough already returning whatever
  # handle_token/3's own default gives KW_DISTINCT's raw text is fine as
  # is; no clause needed here, same reasoning as STRING/DECIMAL/RADIX/
  # INTEGER above.

  def handle_rule(:order_by_clause, %{items: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:order_item_list, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  # `dir` is always a string ("" when absent, "desc"/"ASC"/... when
  # present, any case per @case_insensitive) -- see priv/grammar.aether's
  # own comment on `order_item` for why this is a value check, not
  # Map.has_key?/2, unlike every *rule*-shaped optional in this file.
  # `key` is a full `expr()` now (priv/grammar.aether's own `order_item`
  # comment), not a bare field path -- `key_cap.eval.(ctx)` already
  # returns the fully-tagged shape (`{:field, path}` for the common bare
  # case, same as any other `expression`-derived position).
  def handle_rule(:order_item, %{key: key_cap, dir: dir_cap}, ctx) do
    with {:ok, key, ctx} <- key_cap.eval.(ctx),
         {:ok, dir_text, ctx} <- dir_cap.eval.(ctx) do
      direction = if String.downcase(dir_text) == "desc", do: :desc, else: :asc
      {:ok, {key, direction}, ctx}
    end
  end

  def handle_rule(:limit_clause, %{n: n_cap} = captures, ctx) do
    with {:ok, limit, ctx} <- n_cap.eval.(ctx),
         {:ok, offset, ctx} <- maybe_eval(captures, :offset_clause, ctx) do
      {:ok, {limit, absent_to(nil, offset)}, ctx}
    end
  end

  def handle_rule(:offset_clause, %{n: n_cap}, ctx), do: n_cap.eval.(ctx)

  def handle_rule(:field_list, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  def handle_rule(:disjunction, %{left: left_cap, right: right_caps}, ctx),
    do: eval_chain(left_cap, :right, right_caps, :or, ctx)

  def handle_rule(:conjunction, %{left: left_cap, right: right_caps}, ctx),
    do: eval_chain(left_cap, :right, right_caps, :and, ctx)

  def handle_rule(:negation, %{neg: neg_cap, expr: expr_cap}, ctx) do
    with {:ok, neg_text, ctx} <- neg_cap.eval.(ctx),
         {:ok, expr, ctx} <- expr_cap.eval.(ctx) do
      case neg_text do
        "" -> {:ok, expr, ctx}
        _not -> {:ok, {:not, expr}, ctx}
      end
    end
  end

  # Set comparison's own word-form spellings (lang_spec §5.9: "subset
  # of"/"subset or equal to"/"superset of"/"superset or equal to") --
  # each rule ignores its own captured `marker` token (whichever of
  # `KW_SUBSET`/`KW_SUPERSET` matched carries no information beyond
  # "this rule matched at all") and returns the identical symbol text
  # its own symbol-token sibling (`SUBSET`/`SUBSET_EQ`/`SUPERSET`/
  # `SUPERSET_EQ`) already produces, so `comparison`'s own handlers
  # (below) and `op_from_text/1` need no separate word-form branch --
  # both spellings of a given operator are indistinguishable past this
  # point, exactly as lang_spec intends ("⊆"/"subset or equal to" name
  # the same operator, not two).
  def handle_rule(:subset_of_op, %{marker: _marker}, ctx), do: {:ok, "⊂", ctx}
  def handle_rule(:subset_or_eq_op, %{marker: _marker}, ctx), do: {:ok, "⊆", ctx}
  def handle_rule(:superset_of_op, %{marker: _marker}, ctx), do: {:ok, "⊃", ctx}
  def handle_rule(:superset_or_eq_op, %{marker: _marker}, ctx), do: {:ok, "⊇", ctx}

  def handle_rule(:comparison, %{left: left_cap, op: op_cap, right: right_cap}, ctx) do
    with {:ok, path, ctx} <- left_cap.eval.(ctx),
         {:ok, op_text, ctx} <- op_cap.eval.(ctx),
         {:ok, literal, ctx} <- right_cap.eval.(ctx) do
      {:ok, {:cmp, op_from_text(op_text), path, literal}, ctx}
    end
  end

  # Field-to-field: `{:field, path}` on the right, reusing the same tag
  # Query.body_item/0 uses for a projected field -- structurally
  # identical in both positions (a path naming a field), just a
  # predicate operand here instead of an output marker.
  def handle_rule(:comparison, %{left: left_cap, op: op_cap, right_field: right_cap}, ctx) do
    with {:ok, path, ctx} <- left_cap.eval.(ctx),
         {:ok, op_text, ctx} <- op_cap.eval.(ctx),
         {:ok, right_path, ctx} <- right_cap.eval.(ctx) do
      {:ok, {:cmp, op_from_text(op_text), path, {:field, right_path}}, ctx}
    end
  end

  def handle_rule(:comparison, %{left: left_cap, items: items_cap}, ctx) do
    with {:ok, path, ctx} <- left_cap.eval.(ctx),
         {:ok, items, ctx} <- items_cap.eval.(ctx) do
      {:ok, {:in, path, items}, ctx}
    end
  end

  # `in`'s own computed-list alternatives (grammar's own `comparison`
  # comment) -- `items_expr` resolves to a bare `[String.t()]` when
  # `path` matched (same shape `predicate_lhs`'s own passthrough
  # produces), or an already-tagged `{:call, ...}`/`{:dot, ...}` when
  # `call`/`call_with_path` matched. Only the bare-path shape needs
  # wrapping as `{:field, path}` to be a resolvable expr() -- the other
  # two already are one, distinguished from a plain path by not being a
  # list at all (a path is always `[String.t(), ...]`; `{:call, ...}`/
  # `{:dot, ...}` are tuples), so `is_list/1` alone disambiguates safely.
  def handle_rule(:comparison, %{left: left_cap, items_expr: items_cap}, ctx) do
    with {:ok, path, ctx} <- left_cap.eval.(ctx),
         {:ok, list_expr, ctx} <- items_cap.eval.(ctx) do
      {:ok, {:in, path, wrap_field_path(list_expr)}, ctx}
    end
  end

  # `in`'s own left-hand side (grammar's own `in_lhs` comment) --
  # `lhs_expr` (call_with_path/call/path) passes through completely
  # unwrapped, exactly what `predicate_lhs` alone already produced
  # before this; `lhs_literal` is wrapped `{:literal, value}` so
  # `Scry.Core.Executor.resolve_predicate_lhs/4` can never mistake a
  # literal list value (`[1, 2] in ...`) for a plain field path -- see
  # the grammar's own comment for why that collision is real, not
  # theoretical.
  def handle_rule(:in_lhs, %{lhs_expr: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:in_lhs, %{lhs_literal: cap}, ctx) do
    with {:ok, value, ctx} <- cap.eval.(ctx) do
      {:ok, {:literal, value}, ctx}
    end
  end

  def handle_rule(:list, captures, ctx) do
    with {:ok, items, ctx} <- maybe_eval(captures, :literal_list, ctx) do
      {:ok, absent_to([], items), ctx}
    end
  end

  def handle_rule(:literal, %{KW_NIL: cap}, ctx) do
    with {:ok, _text, ctx} <- cap.eval.(ctx), do: {:ok, nil, ctx}
  end

  def handle_rule(:literal, %{KW_TRUE: cap}, ctx) do
    with {:ok, _text, ctx} <- cap.eval.(ctx), do: {:ok, true, ctx}
  end

  def handle_rule(:literal, %{KW_FALSE: cap}, ctx) do
    with {:ok, _text, ctx} <- cap.eval.(ctx), do: {:ok, false, ctx}
  end

  # STRING/DECIMAL/RADIX/INTEGER are real tokens (unlike the three
  # refiner-target clauses above), so the default single-capture
  # passthrough already gives the right value via handle_token/3 -- no
  # clause needed here.

  def handle_rule(:rational, %{numerator: num_cap, denominator: den_cap}, ctx) do
    with {:ok, numerator, ctx} <- num_cap.eval.(ctx),
         {:ok, denominator, ctx} <- den_cap.eval.(ctx) do
      {:ok, Rational.new(numerator, denominator), ctx}
    end
  end

  def handle_rule(:literal_list, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  # `document`'s own handler's own final step -- `Scry.Core.TypeCheck.
  # check/1` runs unconditionally, exactly like `WithCycleCheck`/
  # `FragmentResolver` above it in `handle_rule(:document, ...)` -- reads
  # `type_decls` straight off the struct just built, so no new parameter
  # needs threading anywhere. A document with no `TYPE` declarations at
  # all sees zero behavior change: every check inside `TypeCheck` is a
  # no-op absent a matching declared field.
  defp finalize_document(query_or_combined, ctx) do
    with :ok <- Scry.Core.TypeCheck.check(query_or_combined) do
      {:ok, query_or_combined, ctx}
    end
  end

  # `document`'s own handler's helper, shared by both `FRAGMENT` and
  # `WITH` -- `Map.new/2` would otherwise silently let a second
  # declaration with the same name win, with no error at all; this makes
  # that a real, reportable compile error instead (tagged by
  # `error_tag`, so a caller can tell which declaration kind it was),
  # before either map reaches the code that assumes it's unambiguous.
  defp build_name_map(decls, error_tag) do
    Enum.reduce_while(decls, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      if Map.has_key?(acc, name) do
        {:halt, {:error, {error_tag, name}}}
      else
        {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  # The grammar's own `DURATION`/`BYTE_SIZE` token shape (`DIGIT+ ("."
  # DIGIT+)? UNIT`) already guarantees digits and letters never mix --
  # splitting on that boundary alone, with no knowledge of which
  # specific unit it is, is unambiguous by construction.
  defp split_number_and_unit(text) do
    [number, unit] =
      Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)([a-zA-Z]+)$/, text, capture: :all_but_first)

    {number, unit}
  end

  defp parse_exact_number(text) do
    case String.split(text, ".", parts: 2) do
      [whole] ->
        String.to_integer(whole)

      [whole, fraction] ->
        numerator = String.to_integer(whole <> fraction)
        denominator = Integer.pow(10, String.length(fraction))
        Rational.new(numerator, denominator)
    end
  end

  # Canonical base unit: seconds. `ns`/`us`/`ms` are exact fractions of a
  # second (never an IEEE-754 approximation, same as every other numeric
  # literal in this file) -- confirmed the grammar never lets an
  # unrecognized unit reach this function, so no catch-all clause is
  # needed (unlike `duration_unit_seconds`'s cousin `eval_aggregate`'s
  # own runtime "unknown function" case, this is a parse-time-only
  # concern already closed by the token's own definition).
  defp duration_unit_seconds("ns"), do: Rational.new(1, 1_000_000_000)
  defp duration_unit_seconds("us"), do: Rational.new(1, 1_000_000)
  defp duration_unit_seconds("ms"), do: Rational.new(1, 1_000)
  defp duration_unit_seconds("s"), do: 1
  defp duration_unit_seconds("m"), do: 60
  defp duration_unit_seconds("h"), do: 3600
  defp duration_unit_seconds("d"), do: 86_400

  # Canonical base unit: bytes. Decimal (SI, powers of 1000) and binary
  # (IEC 60027-2, powers of 1024) are two genuinely different scales for
  # the same-looking prefix letter (`M`/`G`/etc.) -- lang_spec.md §4's
  # own worked example (`10MB` vs `10MiB`) is exactly this distinction,
  # not a typo or a redundant alternative.
  defp byte_size_unit_bytes("B"), do: 1
  defp byte_size_unit_bytes("KB"), do: 1_000
  defp byte_size_unit_bytes("MB"), do: 1_000_000
  defp byte_size_unit_bytes("GB"), do: 1_000_000_000
  defp byte_size_unit_bytes("TB"), do: 1_000_000_000_000
  defp byte_size_unit_bytes("PB"), do: 1_000_000_000_000_000
  defp byte_size_unit_bytes("KiB"), do: 1024
  defp byte_size_unit_bytes("MiB"), do: 1024 * 1024
  defp byte_size_unit_bytes("GiB"), do: 1024 * 1024 * 1024
  defp byte_size_unit_bytes("TiB"), do: 1024 * 1024 * 1024 * 1024
  defp byte_size_unit_bytes("PiB"), do: 1024 * 1024 * 1024 * 1024 * 1024

  defp op_from_text("="), do: :eq
  defp op_from_text("not="), do: :not_eq
  defp op_from_text("<"), do: :lt
  defp op_from_text(">"), do: :gt
  defp op_from_text("<="), do: :le
  defp op_from_text(">="), do: :ge
  defp op_from_text("~"), do: :match
  defp op_from_text("⊂"), do: :subset
  defp op_from_text("⊆"), do: :subset_eq
  defp op_from_text("⊃"), do: :superset
  defp op_from_text("⊇"), do: :superset_eq

  defp arith_op_from_text("+"), do: :add
  defp arith_op_from_text("-"), do: :sub
  defp arith_op_from_text("*"), do: :mul
  defp arith_op_from_text("/"), do: :div

  defp bitwise_op_from_text("&"), do: :band
  defp bitwise_op_from_text("|"), do: :bor

  defp unary_op_from_text("-"), do: :neg
  defp unary_op_from_text("!"), do: :bnot

  # Left-to-right fold over `{op, right}` pairs -- the same shape
  # `eval_chain/5` already folds for `disjunction`/`conjunction`, just
  # with a per-repetition operator instead of one fixed one, so it
  # can't reuse that helper directly.
  defp fold_arith(left, tails) do
    Enum.reduce(tails, left, fn {op, right}, acc -> {:arith, op, acc, right} end)
  end

  # Same fold shape as `fold_arith/2` just above, one precedence tier
  # up -- `{:bitwise, op, left, right}` is `expr()`'s own AST tag for
  # `&`/`|`, kept distinct from `{:arith, ...}` since bitwise operands
  # are integer-only (Scry.Core.QueryOps's own `bitwise/3` raises for
  # anything else), a real, checked constraint `{:arith, ...}` doesn't
  # share.
  defp fold_bitwise(left, tails) do
    Enum.reduce(tails, left, fn {op, right}, acc -> {:bitwise, op, acc, right} end)
  end

  # Same left-to-right fold shape as `fold_arith/2` above, but building
  # `%Scry.Core.CombinedQuery{}` nodes instead of `{:arith, ...}` tuples --
  # `A UNION B EXCEPT C` folds to `%CombinedQuery{op: :except, left:
  # %CombinedQuery{op: :union, left: A, right: B}, right: C}`, exactly
  # `(A UNION B) EXCEPT C`, the correct left-associative grouping
  # (`priv/grammar.aether`'s own `combined_select` comment has the fuller
  # "why not naive right-recursion" reasoning). A `tails == []` fold
  # (no combinator used at all) returns `left` completely unchanged --
  # still a plain `%Query{}`, never wrapped.
  defp fold_combinators(left, tails) do
    Enum.reduce(tails, left, fn {op, right}, acc ->
      %Scry.Core.CombinedQuery{op: op, left: acc, right: right}
    end)
  end

  defp unescape(text), do: unescape(text, [])

  defp unescape(<<"\\\"", rest::binary>>, acc), do: unescape(rest, [acc, ?"])
  defp unescape(<<"\\'", rest::binary>>, acc), do: unescape(rest, [acc, ?'])
  defp unescape(<<"\\\\", rest::binary>>, acc), do: unescape(rest, [acc, ?\\])
  defp unescape(<<"\\n", rest::binary>>, acc), do: unescape(rest, [acc, ?\n])
  defp unescape(<<"\\t", rest::binary>>, acc), do: unescape(rest, [acc, ?\t])

  defp unescape(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    unescape(rest, [acc, <<String.to_integer(hex, 16)::utf8>>])
  end

  defp unescape(<<c::utf8, rest::binary>>, acc), do: unescape(rest, [acc, <<c::utf8>>])
  defp unescape(<<>>, acc), do: IO.iodata_to_binary(acc)

  # An optional *rule* reference has no capture key at all when it
  # didn't match -- see this module's own moduledoc for why that's the
  # check here, not a value inspected after evaluating.
  defp maybe_eval(captures, key, ctx) do
    case Map.fetch(captures, key) do
      {:ok, cap} -> cap.eval.(ctx)
      :error -> {:ok, :absent, ctx}
    end
  end

  # `maybe_eval/3`'s own :absent sentinel, resolved to a real default.
  defp absent_to(default, :absent), do: default
  defp absent_to(_default, value), do: value

  # `comparison`'s own `items_expr:path` alternative resolves to a bare
  # `[String.t()]` (a path's own default passthrough) -- everywhere
  # else in `Query.expr()` a path needs `{:field, ...}` wrapping to be
  # resolvable, so this does exactly that; `{:call, ...}`/`{:dot, ...}`
  # are already correctly tagged and pass through unchanged.
  defp wrap_field_path(path) when is_list(path), do: {:field, path}
  defp wrap_field_path(already_tagged), do: already_tagged

  # `frame_bound`'s own `prec_or_foll` capture text, case-insensitive
  # (this grammar's own file-wide `@case_insensitive` pragma) --
  # "preceding" picks the first tag, anything else (only ever
  # "following", the token choice group's only other member) the
  # second.
  defp frame_bound_tag(pf_text, preceding_tag, following_tag) do
    if String.downcase(pf_text) == "preceding", do: preceding_tag, else: following_tag
  end

  # Reuses Ichor.Actions.eval_all/2 (already correct for both a single
  # capture and a repeated-under-*/+ list of them) rather than
  # reimplementing that fold -- the same trick Ichor's own Prolog
  # test-support Actions module uses for the identical shape.
  defp eval_list(key, caps, ctx) do
    with {:ok, wrapped, ctx} <- Ichor.Actions.eval_all(%{key => caps}, ctx) do
      {:ok, Map.fetch!(wrapped, key), ctx}
    end
  end

  defp eval_chain(left_cap, right_key, right_caps, combinator, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, rights, ctx} <- eval_list(right_key, right_caps, ctx) do
      {:ok, Enum.reduce(rights, left, fn right, acc -> {combinator, acc, right} end), ctx}
    end
  end
end
