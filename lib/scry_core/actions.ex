defmodule ScryCore.Actions do
  @moduledoc """
  Turns `priv/grammar.aether`'s parse tree into `%ScryCore.Query{}` --
  the shared target both Scry front ends converge on (impl_spec.md §7).
  Covers only what that grammar's current Phase 1 subset can produce;
  see its own header for what's deferred.

  Core-only: this module has no idea what a real kind's own EP1(a)/
  EP1(b)/(c)/(d) extension-point rules look like, since none exist yet
  (`scry_time_series` and friends are still just fixture-shaped stands-in
  in `ScryCore.GrammarComposeTest`). Whatever a loaded fragment's
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

  alias ScryCore.{Query, Rational}

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
  # (ScryCore.Executor), never string-interpolated into query text.
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

  # Single-letter tag, `/` the only delimiter -- priv/grammar.aether's
  # own SIGIL comment has the full reasoning (arbitrary-delimiter
  # backreferencing isn't expressible as a plain token pattern). `r` is
  # the one concrete tag lang_spec.md §4 actually specifies; any other
  # is a real, reportable error rather than a silent no-op or a guess at
  # unspecified semantics. `Regex.compile/1`'s own `{:error, {message,
  # index}}` is already a valid `handle_token/3` error shape, passed
  # through unchanged -- same "let the stdlib's own error surface as an
  # ordinary parse error" pattern DATE already established.
  def handle_token(:SIGIL, <<"@", tag::binary-size(1), "/", rest::binary>>, _ctx) do
    content = rest |> String.slice(0..-2//1) |> String.replace("\\/", "/")

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

  @impl true
  def handle_rule(:select, captures, ctx) do
    with {:ok, source, ctx} <- captures.source.eval.(ctx),
         {:ok, ep1a, ctx} <- maybe_eval(captures, :select_ep1a, ctx),
         {:ok, where_pred, ctx} <- maybe_eval(captures, :where_clause, ctx),
         {:ok, group_bys, ctx} <- maybe_eval(captures, :group_by_clause, ctx),
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

      {:ok,
       %Query{
         source: source,
         wheres: wheres,
         group_bys: absent_to([], group_bys),
         havings: havings,
         distinct: distinct != :absent,
         order_bys: absent_to([], order_bys),
         limit: limit,
         offset: offset,
         required: required != :absent,
         select: select,
         variant: variant
       }, ctx}
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

  # `{:spread, name}` -- a placeholder `ScryCore.FragmentResolver`
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
  # these into the name => body_items map ScryCore.FragmentResolver
  # needs; nothing about a fragment_decl's own shape survives past that.
  def handle_rule(:fragment_decl, %{name: name_cap, body: body_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, body, ctx} <- body_cap.eval.(ctx) do
      {:ok, {name, body}, ctx}
    end
  end

  # `select_cap`'s own handler already returns a real %ScryCore.Query{}
  # -- a WITH-bound value is a full query, not a special restricted
  # shape (ScryCore.Query's own moduledoc), so no extra wrapping is
  # needed here, the same reasoning body_item's own `select` clause
  # already relies on.
  def handle_rule(:with_decl, %{name: name_cap, select: select_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, query, ctx} <- select_cap.eval.(ctx) do
      {:ok, {name, query}, ctx}
    end
  end

  # `combined_select`'s own handler already returns either a real
  # %ScryCore.Query{} (no combinator used) or a %ScryCore.CombinedQuery{}
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
  # comments have the full reasoning). `fragment_decl`/`with_decl` are
  # both bare/unrenamed and `*`-repeated, so each always has its own key
  # -- `[]`, not a missing one, when absent (confirmed empirically, same
  # finding as `additive_tail`/`when_clause` elsewhere in this module),
  # so no `maybe_eval` is needed here the way an *optional* rule
  # reference would need.
  #
  # Duplicate `FRAGMENT`/`WITH` names are each a real, reportable compile
  # error (`Map.new/2` would otherwise silently let the second
  # declaration win) -- checked before handing either map onward, which
  # assumes it's already unambiguous. `ScryCore.WithCycleCheck` runs
  # after the map is built but doesn't need the final query at all (a
  # cycle is a property of the bindings alone) -- ordered before
  # `FragmentResolver` for no real reason beyond it being the cheaper,
  # `select`-independent check to fail on first.
  #
  # `select_cap` (really `combined_select`, renamed -- see
  # priv/grammar.aether's own `document` comment) may itself evaluate to
  # either a %Query{} or a %CombinedQuery{} -- `ScryCore.FragmentResolver
  # .resolve/2` already dispatches on both (its own moduledoc), and
  # `with_bindings` attaches to whichever type comes back, since either
  # can legitimately be the top-level result of a document.
  def handle_rule(
        :document,
        %{fragment_decl: frag_caps, with_decl: with_caps, select: select_cap},
        ctx
      ) do
    with {:ok, frags, ctx} <- eval_list(:fragment_decl, frag_caps, ctx),
         {:ok, fragments} <- build_name_map(frags, :duplicate_fragment),
         {:ok, withs, ctx} <- eval_list(:with_decl, with_caps, ctx),
         {:ok, with_bindings} <- build_name_map(withs, :duplicate_with),
         :ok <- ScryCore.WithCycleCheck.check(with_bindings),
         {:ok, result, ctx} <- select_cap.eval.(ctx) do
      case ScryCore.FragmentResolver.resolve(result, fragments) do
        {:ok, %Query{} = resolved} ->
          {:ok, %Query{resolved | with_bindings: with_bindings}, ctx}

        {:ok, %ScryCore.CombinedQuery{} = resolved} ->
          {:ok, %ScryCore.CombinedQuery{resolved | with_bindings: with_bindings}, ctx}

        {:error, _} = err ->
          err
      end
    end
  end

  def handle_rule(:field_body_item, %{alias: alias_cap, expr: expr_cap}, ctx) do
    with {:ok, alias_name, ctx} <- alias_cap.eval.(ctx),
         {:ok, expr, ctx} <- expr_cap.eval.(ctx) do
      {:ok, {:computed, alias_name, expr}, ctx}
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

  # `additive_tail`/`mult_tail` (both `*`-repeated) always produce their
  # own key, an empty list when there were zero repetitions -- unlike a
  # `?`-optional *rule* reference, which produces no key at all when
  # absent (confirmed empirically, priv/grammar.aether's own `power`
  # comment has the fuller story). No `maybe_eval`/absence check needed
  # here because of that: `eval_list` already handles "zero or more"
  # uniformly, the same helper `path`'s own `tail` already relies on.
  def handle_rule(:expression, %{left: left_cap, additive_tail: tail_caps}, ctx) do
    with {:ok, left, ctx} <- left_cap.eval.(ctx),
         {:ok, tails, ctx} <- eval_list(:additive_tail, tail_caps, ctx) do
      {:ok, fold_arith(left, tails), ctx}
    end
  end

  # Returns its own `{op, right}` piece, not a folded `{:arith, ...}`
  # tuple -- `additive_tail` has no idea what `left`/the running
  # accumulator is, only `expression`'s own handler (`fold_arith/2`)
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

  # lang_spec §5.8's built-in functions (sum/avg/count/min/max, this
  # phase's real set) -- ScryCore.Executor.eval_aggregate/5 decides
  # which `name`s it actually knows how to run, not this module (same
  # split as body_item_ep1's own {:variant, value}, a construct the
  # grammar accepts generally that only *some* of the pipeline
  # ultimately executes).
  def handle_rule(:call, %{name: name_cap, args: args_cap}, ctx) do
    with {:ok, name, ctx} <- name_cap.eval.(ctx),
         {:ok, args, ctx} <- args_cap.eval.(ctx) do
      {:ok, {:call, name, args}, ctx}
    end
  end

  def handle_rule(:call_args, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

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

  # Returns its own `{predicate, then_expr}` pair -- `ScryCore.Executor`
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

  def handle_rule(:body_list, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  def handle_rule(:where_clause, %{cond: cond_cap}, ctx), do: cond_cap.eval.(ctx)

  def handle_rule(:group_by_clause, %{fields: cap}, ctx), do: cap.eval.(ctx)

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
  def handle_rule(:order_item, %{field: field_cap, dir: dir_cap}, ctx) do
    with {:ok, field, ctx} <- field_cap.eval.(ctx),
         {:ok, dir_text, ctx} <- dir_cap.eval.(ctx) do
      direction = if String.downcase(dir_text) == "desc", do: :desc, else: :asc
      {:ok, {field, direction}, ctx}
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

  defp op_from_text("="), do: :eq
  defp op_from_text("not="), do: :not_eq
  defp op_from_text("<"), do: :lt
  defp op_from_text(">"), do: :gt
  defp op_from_text("<="), do: :le
  defp op_from_text(">="), do: :ge
  defp op_from_text("~"), do: :match

  defp arith_op_from_text("+"), do: :add
  defp arith_op_from_text("-"), do: :sub
  defp arith_op_from_text("*"), do: :mul
  defp arith_op_from_text("/"), do: :div

  # Left-to-right fold over `{op, right}` pairs -- the same shape
  # `eval_chain/5` already folds for `disjunction`/`conjunction`, just
  # with a per-repetition operator instead of one fixed one, so it
  # can't reuse that helper directly.
  defp fold_arith(left, tails) do
    Enum.reduce(tails, left, fn {op, right}, acc -> {:arith, op, acc, right} end)
  end

  # Same left-to-right fold shape as `fold_arith/2` above, but building
  # `%ScryCore.CombinedQuery{}` nodes instead of `{:arith, ...}` tuples --
  # `A UNION B EXCEPT C` folds to `%CombinedQuery{op: :except, left:
  # %CombinedQuery{op: :union, left: A, right: B}, right: C}`, exactly
  # `(A UNION B) EXCEPT C`, the correct left-associative grouping
  # (`priv/grammar.aether`'s own `combined_select` comment has the fuller
  # "why not naive right-recursion" reasoning). A `tails == []` fold
  # (no combinator used at all) returns `left` completely unchanged --
  # still a plain `%Query{}`, never wrapped.
  defp fold_combinators(left, tails) do
    Enum.reduce(tails, left, fn {op, right}, acc ->
      %ScryCore.CombinedQuery{op: op, left: acc, right: right}
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
