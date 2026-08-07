defmodule Scry.Core.GrammarCompose do
  @moduledoc """
  Merges core's grammar with a kind fragment's, per impl_spec.md §4 --
  the pre-processing step Ichor has no native equivalent for, sitting
  between independently parsing each `.aether` source (both succeed on
  their own; core's EP1/EP2 extension points are dangling `RuleRef`s by
  design, and `Aether.Reader`/`Aether.Eval` don't validate ordinary
  rule-body references, only `@root`/`@skip`/`@keywords`/`@refine`) and
  handing the merged result to `Ichor.generate_from_grammar/2`, which
  runs `Grammar.Analysis` and codegen exactly as it would for any
  hand-written single-file grammar.

  Two authoring requirements this module enforces, both found by
  actually running the composition against a real fragment rather than
  assumed from reading Ichor's source alone:

    - **A fragment must declare `@skip` matching core's own skip token
      name.** Aether bakes default skip-splicing into a rule's IR at
      *parse time*, using whichever token is active in *that file* --
      not the merged grammar's eventual skip token. A fragment that
      defaults to plain `SPACE` (no `@skip` pragma) while core uses
      `TRIVIA` (built from `SPACE`) ends up with an unmatchable
      `Star(RuleRef(:SPACE))` baked into its own rules post-merge: once
      `TRIVIA` is the *active* skip token, `SPACE` becomes invisible
      trivia the tokenizer consumes before any rule -- including an
      explicit reference to `SPACE` itself -- ever sees it. `merge/2`
      checks this and raises a clear, actionable error instead of
      leaving a fragment author to debug a cryptic "did not expect more
      input" parse failure with no connection to its real cause.
    - **A shared/common token or rule name (`TRIVIA`, `COMMENT`, ...) may
      be declared in both core and a fragment only if the two
      declarations are structurally identical.** A fragment needs its
      own local copy to satisfy Aether's eager per-file validation of
      `@skip` (same class of eager check as `@keywords`/`@refine`), but
      that copy is never meant to *diverge* from core's -- it's
      discarded in favor of core's own at merge time. Any other name
      defined by both is a genuine collision (lang_spec.md §2's
      grammar-composition-time keyword-collision rule) and raises.

  A third, more fundamental requirement, found while working out how
  `select_ep1a` should actually behave once more than one kind is
  loaded: **an extension point is not "exactly one fragment may define
  this rule."** lang_spec.md §5.2 already says as much for real --
  `last` (time-series) and `deep` (document) both nominate the same
  "before WHERE" position, and nothing stops a build from loading both
  kinds at once, each contributing its own alternative there. Treating
  a second fragment's `select_ep1a` as a collision (the general rule
  above) would make that combination impossible. `extension_points/0`
  below names every rule this applies to; `merge/2` folds *every*
  loaded fragment's contribution into one `Choice`, deduplicating an
  exact repeat rather than erroring, instead of requiring exact
  identity or raising. Core itself has to carry a real "never matches"
  default for each (`priv/grammar.aether`'s `NEVER := []`, an empty
  character class -- not a `!`-negated lookahead, which turns out to
  mean "always succeeds with zero width," the opposite of what's
  needed here), so a build with zero kinds contributing at that
  position still compiles into a genuinely usable grammar rather than
  one with a dangling reference.
  """

  alias Ichor.Error

  # The only Grammar.IR node type this module still needs to name
  # directly -- strip_meta/1's own comment explains why the other 15
  # node types this module used to alias/pattern-match by name (one
  # `defp strip_meta(%NodeType{...})` clause each) no longer appear
  # here at all: struct-literal syntax for any of them needs the target
  # module's own definition at *compile* time, which breaks compiling
  # scry_core as a dependency for anyone who never touches grammar
  # composition. `Choice` survives only as a plain atom reference
  # (`is_struct(choice, Choice)`, `struct(Choice, ...)`), never struct-
  # literal syntax -- an `alias` directive itself is pure compile-time
  # name substitution, needing no more from `Grammar.IR.Choice` than
  # any other bare atom would.
  alias Grammar.IR.Choice

  @doc """
  Merges `core` (an `%Aether.Grammar{}`, not yet run through
  `Grammar.Analysis`) with `fragment` (same) -- or, to compose more than
  one fragment, fold this over a list: `Enum.reduce(fragments, core,
  fn fragment, acc -> {:ok, merged} = merge(acc, fragment); merged end)`.
  Returns the merged `%Aether.Grammar{}`, still not yet analyzed --
  callers hand it to `Ichor.generate_from_grammar/2` (or
  `Grammar.Analysis.run/1` directly, for just the completeness check)
  themselves.

  `core`'s own `root`/`skip`/`engine`/`case_insensitive` win; a
  fragment's copies of those settings are never consulted beyond the
  skip-match check above. An extension-point rule name
  (`extension_points/0`) unions every contribution instead of requiring
  identity -- see this module's own moduledoc.
  """
  @spec merge(Aether.Grammar.t(), Aether.Grammar.t()) ::
          {:ok, Aether.Grammar.t()} | {:error, Error.t()}
  def merge(core, fragment)
      when is_struct(core, Aether.Grammar) and is_struct(fragment, Aether.Grammar) do
    with :ok <- check_skip_match(core, fragment),
         {:ok, tokens} <- merge_maps(core.tokens, fragment.tokens, "token"),
         {:ok, rules} <- merge_maps(core.rules, fragment.rules, "rule", extension_points()) do
      {:ok,
       %{
         core
         | tokens: tokens,
           rules: rules,
           token_order: merge_token_order(core.token_order, fragment.token_order),
           rule_order: core.rule_order ++ (fragment.rule_order -- core.rule_order),
           refiners: Map.merge(core.refiners, fragment.refiners)
       }}
    end
  end

  # Every extension-point rule name core declares -- see this module's
  # own moduledoc for why these specifically need union-not-collision
  # merge semantics. Grows as core adds more.
  #
  # A plain list, not a MapSet -- Dialyzer has known, longstanding
  # friction with MapSet's opaque internal representation whenever the
  # set comes from a small compile-time-constant literal (success
  # typing narrows straight through the literal, then flags every
  # MapSet.member?/2 call site as an opaqueness violation against its
  # own inferred type). Real friction, not a real bug; a plain list and
  # `in` sidesteps it entirely rather than fighting or suppressing it,
  # and at this size (two entries, growing slowly) there's no
  # performance reason to prefer a MapSet anyway.
  @spec extension_points() :: [atom()]
  defp extension_points, do: [:select_ep1a, :body_item_ep1]

  defp check_skip_match(%{skip: same}, %{skip: same}), do: :ok

  defp check_skip_match(core, fragment) do
    {:error,
     Error.new(
       message:
         "fragment's @skip (#{inspect(fragment.skip)}) doesn't match core's " <>
           "(#{inspect(core.skip)}) -- a fragment must declare `@skip #{core.skip}` " <>
           "(and a locally-identical definition of it) to match core's skip token, " <>
           "or its rules' auto-spliced whitespace handling will silently break once merged",
       stage: :analysis
     )}
  end

  # A name in both maps is only a real collision if the two definitions
  # actually differ -- a fragment's required local redeclaration of a
  # shared token like TRIVIA (to satisfy Aether's own eager @skip
  # validation) is expected to be identical to core's, and core's copy
  # wins without complaint. `strip_meta/1` first: source-span metadata
  # naturally differs between two files even when the matched shape is
  # identical, so it can't be part of the equality check.
  #
  # A name in `extension_points`, though, is never a collision at all --
  # both sides' definitions are unioned into one Choice instead (see
  # this module's own moduledoc for why more than one fragment needs to
  # be able to contribute to the same extension point simultaneously).
  defp merge_maps(core_map, fragment_map, kind, extension_points \\ []) do
    conflicts =
      for {name, fragment_def} <- fragment_map,
          name not in extension_points,
          Map.has_key?(core_map, name),
          strip_meta(Map.fetch!(core_map, name)) != strip_meta(fragment_def),
          do: name

    case conflicts do
      [] ->
        merged =
          Enum.reduce(fragment_map, core_map, fn {name, fragment_def}, acc ->
            if name in extension_points do
              Map.update(acc, name, fragment_def, &union_rule(&1, fragment_def))
            else
              Map.put_new(acc, name, fragment_def)
            end
          end)

        {:ok, merged}

      names ->
        {:error,
         Error.new(
           message:
             "#{kind} name collision at grammar composition: #{Enum.map_join(names, ", ", &inspect/1)} " <>
               "declared differently by core and this fragment",
           stage: :analysis
         )}
    end
  end

  # Folds a fragment's contribution into an extension point's existing
  # definition -- flattens into an already-Choice accumulator (the
  # normal case once a second, third, ... fragment contributes) rather
  # than nesting a Choice inside a Choice, and skips an exact repeat
  # (the same fragment merged twice, or two fragments that happen to
  # define the identical thing) rather than adding dead PEG alternatives
  # Grammar.Analysis's own duplicate-alternative lint would flag anyway.
  defp union_rule(choice, new_def) when is_struct(choice, Choice) do
    new_stripped = strip_meta(new_def)

    if Enum.any?(choice.exprs, &(strip_meta(&1) == new_stripped)) do
      choice
    else
      %{choice | exprs: choice.exprs ++ [new_def]}
    end
  end

  defp union_rule(existing_def, new_def) do
    if strip_meta(existing_def) == strip_meta(new_def) do
      existing_def
    else
      struct(Choice, exprs: [existing_def, new_def], meta: nil)
    end
  end

  # Every Grammar.IR node carries source-span metadata that naturally
  # differs between two files even when the matched shape is identical
  # -- stripped before the equality check in merge_maps/3. Generic
  # (recurse into any struct/list-of-structs field, zero `:meta`, leave
  # every other scalar field -- a module name, a rule name, `min`/`max`,
  # a `CharClass`'s own `ranges`, ... -- untouched), *not* one hand-
  # written clause per Grammar.IR node type as an earlier version of
  # this had: `%Module{...}` struct-literal syntax (construction *or*
  # pattern) requires the target module's own struct definition at
  # *compile* time, which none of Grammar.IR's modules can be here --
  # this file's own moduledoc/`merge/2`'s own doc explain why (`ichor`
  # is a genuine compile-time dependency of *whoever calls* `merge/2`,
  # never of `scry_core`'s own `lib/`, which has to compile cleanly
  # even for a downstream package -- `scry_test_engine_core`, a real
  # future adapter -- that never touches grammar composition at all).
  # `struct/2`, `Map.from_struct/1`, `is_struct/1`, and a bare `term.
  # __struct__` are all ordinary runtime-dispatched functions -- no
  # compile-time struct knowledge needed for any of them, confirmed via
  # a clean rebuild of a downstream consumer (this file's own earlier,
  # exhaustive version failed exactly that check).
  defp strip_meta(term) when is_struct(term) do
    term
    |> Map.from_struct()
    |> Enum.into(%{}, fn
      {:meta, _} -> {:meta, nil}
      {key, value} -> {key, strip_meta(value)}
    end)
    |> then(&struct(term.__struct__, &1))
  end

  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta(other), do: other

  # Naive `core_order ++ fragment_order` would put every fragment token
  # after ALL of core's, including :IDENT -- meaning any fragment
  # keyword sharing IDENT's maximal-munch length always loses the
  # declaration-order tie-break and never actually reclassifies away
  # from IDENT. Every fragment-contributed token is therefore inserted
  # immediately before :IDENT instead of appended at the end. :IDENT is
  # the only base identifier-shaped token in this design (§2 of this
  # module's moduledoc), so this one special case covers every kind's
  # keyword tokens, not just one fragment's.
  defp merge_token_order(core_order, fragment_order) do
    new_from_fragment = fragment_order -- core_order

    Enum.reduce(core_order, [], fn
      :IDENT, acc -> [:IDENT | Enum.reverse(new_from_fragment)] ++ acc
      tok, acc -> [tok | acc]
    end)
    |> Enum.reverse()
  end
end
