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
  def handle_token(:STRING, text, _ctx), do: {:ok, String.slice(text, 1..-2//1)}

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
         {:ok, select, ctx} <- captures.body.eval.(ctx) do
      variant = if ep1a == :absent, do: %{}, else: %{select_ep1a: ep1a}
      wheres = if where_pred == :absent, do: [], else: [where_pred]
      {:ok, %Query{source: source, wheres: wheres, select: select, variant: variant}, ctx}
    end
  end

  def handle_rule(:path, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  # A nested query -- select's own handler already returns %Query{}
  # directly, so no extra wrapping is needed here (Query.body_item/0).
  def handle_rule(:body_item, %{select: cap}, ctx), do: cap.eval.(ctx)

  def handle_rule(:body_item, %{body_item_ep1: cap}, ctx) do
    with {:ok, value, ctx} <- cap.eval.(ctx), do: {:ok, {:variant, value}, ctx}
  end

  def handle_rule(:body_item, %{path: cap}, ctx) do
    with {:ok, path, ctx} <- cap.eval.(ctx), do: {:ok, {:field, path}, ctx}
  end

  def handle_rule(:body_list, %{head: head_cap, tail: tail_caps}, ctx) do
    with {:ok, head, ctx} <- head_cap.eval.(ctx),
         {:ok, tail, ctx} <- eval_list(:tail, tail_caps, ctx) do
      {:ok, [head | tail], ctx}
    end
  end

  def handle_rule(:where_clause, %{cond: cond_cap}, ctx), do: cond_cap.eval.(ctx)

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

  def handle_rule(:comparison, %{left: left_cap} = captures, ctx) do
    with {:ok, path, ctx} <- left_cap.eval.(ctx),
         {:ok, items, ctx} <- maybe_eval(captures, :literal_list, ctx) do
      {:ok, {:in, path, if(items == :absent, do: [], else: items)}, ctx}
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

  defp op_from_text("="), do: :eq
  defp op_from_text("not="), do: :not_eq
  defp op_from_text("<"), do: :lt
  defp op_from_text(">"), do: :gt
  defp op_from_text("<="), do: :le
  defp op_from_text(">="), do: :ge

  # An optional *rule* reference has no capture key at all when it
  # didn't match -- see this module's own moduledoc for why that's the
  # check here, not a value inspected after evaluating.
  defp maybe_eval(captures, key, ctx) do
    case Map.fetch(captures, key) do
      {:ok, cap} -> cap.eval.(ctx)
      :error -> {:ok, :absent, ctx}
    end
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
