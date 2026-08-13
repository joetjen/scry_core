defmodule Scry.Core.GrammarComposeTest do
  use ExUnit.Case, async: true

  alias Scry.Core.GrammarCompose

  defmodule NoActions do
    @moduledoc false
  end

  @core_source File.read!("priv/grammar.aether")

  # A fragment standing in for a real kind library's own grammar file
  # (impl_spec.md §4) -- deliberately not scry_time_series, which
  # doesn't exist yet, but shaped the same way: fills core's EP1(a)
  # extension point (`select_ep1a`) with a `LAST <duration>`-style
  # header modifier, contributing its own keyword token directly
  # (`KW_LAST := "last"`) rather than via `@keywords`/`@refine`, since a
  # fragment can't eagerly reference core's IDENT from its own file
  # (Aether validates `@keywords`'/`@refine`'s base token locally).
  @time_series_like_fragment """
  @grammar "fake_time_series_fragment"
  @root select_ep1a
  @case_insensitive
  @skip TRIVIA

  ; must match core's own skip token exactly (name and definition) --
  ; discarded at merge time in favor of core's, but required locally to
  ; satisfy Aether's own eager per-file @skip validation.
  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  select_ep1a := KW_LAST value:INTEGER

  KW_LAST := "last"
  """

  # A second, independent fragment contributing a *different*
  # alternative to the same extension point -- standing in for
  # scry_document's `deep` (lang_spec §5.2), which nominates the exact
  # same "before WHERE" position `last` does. Proves the real
  # requirement: more than one kind can load simultaneously and each
  # still gets its own working alternative there.
  @document_like_fragment """
  @grammar "fake_document_fragment"
  @root select_ep1a
  @case_insensitive
  @skip TRIVIA

  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  select_ep1a := KW_DEEP

  KW_DEEP := "deep"
  """

  # An EP1(b) block-opening construct, standing in for scry_graph's
  # `VIA edge { body }` (lang_spec §8.1) -- fills body_item_ep1, not
  # select_ep1a, and its own body recurses straight back into core's
  # body_list (an ordinary dangling reference, exactly like referencing
  # KW_WHERE above -- resolved once merged, not before). This is the
  # actual point of testing an EP1(b) shape specifically: EP1(a)
  # (select_ep1a) never had to compose with anything of core's own, but
  # a block-opening construct's body is *itself* built from core's body
  # grammar, recursively.
  @graph_like_fragment """
  @grammar "fake_graph_fragment"
  @root body_item_ep1
  @case_insensitive
  @skip TRIVIA

  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  body_item_ep1 := KW_VIA edge:path LBRACE inner:body_list RBRACE

  KW_VIA := "via"
  """

  # An EP1(e) infix comparison-tier operator, standing in for
  # scry_search's `<field> SEARCH <string>` (lang_spec §8.5) -- fills
  # `comparison_ep1e`, the third extension point, in `comparison`'s own
  # top-level alternation, not a nested position the way `body_item_ep1`
  # reuses `body_list` recursively. Unlike either EP1(a) fragment above,
  # this one's own `right` is deliberately `STRING` specifically, not
  # `literal`/`path` the way core's own `comparison` alternatives are --
  # `SEARCH`'s own right-hand side is always a fuzzy-match query string,
  # never a field reference or an arbitrary literal.
  @search_like_fragment """
  @grammar "fake_search_fragment"
  @root comparison_ep1e
  @case_insensitive
  @skip TRIVIA

  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  comparison_ep1e := left:predicate_lhs KW_SEARCH right:STRING

  KW_SEARCH := "search"
  """

  @mismatched_skip_fragment """
  @grammar "fake_bad_fragment"
  @root select_ep1a

  select_ep1a := KW_LAST value:INTEGER

  KW_LAST := "last"
  """

  @colliding_fragment """
  @grammar "fake_colliding_fragment"
  @root select_ep1a
  @case_insensitive
  @skip TRIVIA

  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  select_ep1a := KW_LAST value:INTEGER

  ; collides with core's own INTEGER (a different shape: hex digits, not
  ; decimal) -- must be rejected, not silently overwritten.
  INTEGER := HEX+
  KW_LAST := "last"
  """

  defp parse!(source, file \\ "test.aether") do
    {:ok, grammar} = Aether.Parser.parse(source, file)
    grammar
  end

  # `@root document` now (priv/grammar.aether's own `document` comment)
  # -- every real query text parses as `fragment_decl* with_decl*
  # combined_select`, not `select` alone, and `combined_select` itself
  # always wraps a bare `select` under its own `head` key (`combined_select
  # := head:select combinator_tail*`) even when no combinator is used.
  # None of the tests below are actually about FRAGMENT/`WITH`/combinators
  # (those have their own test modules); they're exercising
  # GrammarCompose/extension-point mechanics that all happen to live
  # inside `select`, so this just unwraps the two extra layers of node
  # the real root always wraps around it, uniformly.
  defp parse_select!(grammar, source) do
    {:ok,
     %Ichor.Node{
       rule: :document,
       captures: %{select: %Ichor.Node{rule: :combined_select, captures: %{head: select_node}}}
     }} = Grammar.VM.run(grammar, source, NoActions, nil)

    select_node
  end

  describe "core alone" do
    test "parses cleanly and passes Grammar.Analysis -- a zero-kind build must still compile" do
      core = parse!(@core_source, "priv/grammar.aether")

      # Not "fails, since select_ep1a is unfilled" -- that was true only
      # of an earlier design where the extension point was a genuinely
      # dangling reference. Real builds with no kind contributing at a
      # given extension point (scry_relational alone, say) still need a
      # working parser; core itself now supplies a real "always fails"
      # default (`NEVER`, priv/grammar.aether) precisely so this holds.
      assert {:ok, _analyzed} = Grammar.Analysis.run(core)
    end

    test "the unfilled extension point genuinely never matches, it's not just permissive" do
      core = parse!(@core_source, "priv/grammar.aether")
      {:ok, analyzed} = Grammar.Analysis.run(core)

      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(analyzed, ~s(SELECT metric { name }))

      refute Map.has_key?(captures, :select_ep1a)

      assert {:error, _} =
               Grammar.VM.run(analyzed, ~s(SELECT metric last 5 { name }), NoActions, nil)
    end
  end

  describe "merge/2 with a correctly-authored fragment" do
    setup do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@time_series_like_fragment)
      {:ok, merged} = GrammarCompose.merge(core, fragment)
      %{merged: merged}
    end

    test "produces a grammar that passes Grammar.Analysis", %{merged: merged} do
      assert {:ok, _analyzed} = Grammar.Analysis.run(merged)
    end

    test "parses a query exercising both core and the extension point", %{merged: merged} do
      {:ok, analyzed} = Grammar.Analysis.run(merged)

      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(analyzed, ~s(SELECT metric last 5 { name }))

      assert %Ichor.Node{rule: :path, captures: %{head: "metric"}} = captures.source
      assert %Ichor.Node{rule: :select_ep1a, captures: ep1a} = captures.select_ep1a
      assert ep1a.value == "5"
      assert Map.fetch!(ep1a, :KW_LAST) == "last"
    end

    test "the extension-point keyword is case-insensitive, matching core's own keywords", %{
      merged: merged
    } do
      {:ok, analyzed} = Grammar.Analysis.run(merged)

      assert %Ichor.Node{rule: :select} =
               parse_select!(analyzed, ~s(select metric LAST 5 { name }))
    end
  end

  describe "merge/2 with two simultaneously-loaded fragments" do
    setup do
      core = parse!(@core_source, "priv/grammar.aether")
      time_series = parse!(@time_series_like_fragment, "time_series.aether")
      document = parse!(@document_like_fragment, "document.aether")

      {:ok, once_merged} = GrammarCompose.merge(core, time_series)
      {:ok, twice_merged} = GrammarCompose.merge(once_merged, document)
      {:ok, analyzed} = Grammar.Analysis.run(twice_merged)
      %{grammar: analyzed}
    end

    test "both kinds' alternatives work, independently, in the same build", %{grammar: g} do
      assert %Ichor.Node{rule: :select, captures: last_captures} =
               parse_select!(g, ~s(SELECT metric last 5 { name }))

      assert %Ichor.Node{rule: :select_ep1a, captures: %{value: "5"}} =
               last_captures.select_ep1a

      assert %Ichor.Node{rule: :select, captures: deep_captures} =
               parse_select!(g, ~s(SELECT metric deep { name }))

      # Unwrapped to the raw text, not a %Ichor.Node{} -- select_ep1a's
      # document-like alternative has exactly one capture (KW_DEEP
      # alone), and Ichor.Actions' own single-capture-passthrough
      # default applies per rule, same as `last`'s two-capture
      # alternative building a real node above is also just that
      # default, not special extension-point behavior.
      assert deep_captures.select_ep1a == "deep"
    end

    test "the position is still absent, not ambiguous, when neither is used", %{grammar: g} do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(g, ~s(SELECT metric { name }))

      refute Map.has_key?(captures, :select_ep1a)
    end
  end

  describe "merge/2 with an EP1(b) block-opening fragment (body_item_ep1)" do
    setup do
      core = parse!(@core_source, "priv/grammar.aether")
      graph = parse!(@graph_like_fragment, "graph.aether")
      {:ok, merged} = GrammarCompose.merge(core, graph)
      {:ok, analyzed} = Grammar.Analysis.run(merged)
      %{grammar: analyzed}
    end

    test "the block construct itself parses as a body item", %{grammar: g} do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(g, ~s(SELECT users { name, via knows { id } }))

      assert %Ichor.Node{rule: :body_list, captures: body} = captures.body
      # `body_list_tail` is right-recursive now (priv/grammar.aether's
      # own comment on it has the full reasoning), so the second item
      # sits one level down, under its own `tail` key -- not a flat
      # list the way `path`'s own `tail` still is.
      assert %Ichor.Node{rule: :body_list_tail, captures: %{tail: via_item}} =
               body.body_list_tail

      assert %Ichor.Node{rule: :body_item_ep1, captures: via} = via_item
      assert %Ichor.Node{rule: :path, captures: %{head: "knows"}} = via.edge
    end

    test "the fragment's own body recurses back into core's body_list, not a copy of it", %{
      grammar: g
    } do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(g, ~s(SELECT users { via knows { id, name } }))

      %Ichor.Node{rule: :body_list, captures: %{head: via_item}} = captures.body
      %Ichor.Node{rule: :body_item_ep1, captures: via} = via_item

      assert %Ichor.Node{rule: :body_list, captures: inner_body} = via.inner
      assert %Ichor.Node{rule: :path, captures: %{head: "id"}} = inner_body.head
    end

    test "still falls back to a plain field when the construct isn't used", %{grammar: g} do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(g, ~s(SELECT users { name }))

      assert %Ichor.Node{rule: :body_list, captures: %{head: %Ichor.Node{rule: :path}}} =
               captures.body
    end
  end

  describe "merge/2 with an EP1(e) infix comparison-tier fragment (comparison_ep1e)" do
    setup do
      core = parse!(@core_source, "priv/grammar.aether")
      search = parse!(@search_like_fragment, "search.aether")
      {:ok, merged} = GrammarCompose.merge(core, search)
      {:ok, analyzed} = Grammar.Analysis.run(merged)
      %{grammar: analyzed}
    end

    # `where_clause.cond` always wraps a bare comparison in `disjunction
    # -> conjunction -> negation` (ordinary precedence climbing, no
    # `AND`/`OR`/`NOT` actually used here) -- unwraps down to whichever
    # `comparison` alternative actually matched, the same way `sorts
    # -before?`'s own callers never see the climbing layers either.
    defp unwrap_comparison(%Ichor.Node{rule: :disjunction, captures: %{left: conjunction}}),
      do: unwrap_comparison(conjunction)

    defp unwrap_comparison(%Ichor.Node{rule: :conjunction, captures: %{left: negation}}),
      do: unwrap_comparison(negation)

    defp unwrap_comparison(%Ichor.Node{rule: :negation, captures: %{expr: comparison}}),
      do: comparison

    test "the infix operator itself parses as an ordinary WHERE comparison", %{grammar: g} do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(
                 g,
                 ~s(SELECT articles WHERE content SEARCH "machine learning" { title })
               )

      assert %Ichor.Node{rule: :where_clause, captures: %{cond: cond_node}} =
               captures.where_clause

      assert %Ichor.Node{rule: :comparison_ep1e, captures: search_captures} =
               unwrap_comparison(cond_node)

      assert %Ichor.Node{rule: :path, captures: %{head: "content"}} = search_captures.left
      assert search_captures.right == ~s("machine learning")
    end

    test "composes with an ordinary core AND alongside it", %{grammar: g} do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(
                 g,
                 ~s(SELECT articles WHERE category = "research" AND content SEARCH "ml" { title })
               )

      assert %Ichor.Node{rule: :where_clause, captures: %{cond: cond_node}} =
               captures.where_clause

      assert %Ichor.Node{rule: :disjunction, captures: %{left: conjunction}} = cond_node

      assert %Ichor.Node{
               rule: :conjunction,
               captures: %{left: left_negation, right: [right_negation]}
             } = conjunction

      assert %Ichor.Node{rule: :negation, captures: %{expr: left_comparison}} = left_negation
      assert %Ichor.Node{rule: :comparison, captures: _} = left_comparison

      assert %Ichor.Node{rule: :negation, captures: %{expr: right_comparison}} = right_negation
      assert %Ichor.Node{rule: :comparison_ep1e, captures: _} = right_comparison
    end

    test "still falls back to an ordinary comparison when the construct isn't used", %{
      grammar: g
    } do
      assert %Ichor.Node{rule: :select, captures: captures} =
               parse_select!(g, ~s(SELECT articles WHERE category = "research" { title }))

      assert %Ichor.Node{rule: :where_clause, captures: %{cond: cond_node}} =
               captures.where_clause

      assert %Ichor.Node{rule: :comparison, captures: _} = unwrap_comparison(cond_node)
    end
  end

  describe "merge/2 skip-mismatch check" do
    test "rejects a fragment whose @skip doesn't match core's, with an actionable message" do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@mismatched_skip_fragment)

      assert {:error, error} = GrammarCompose.merge(core, fragment)
      assert error.message =~ "@skip"
      assert error.message =~ inspect(:SPACE)
      assert error.message =~ inspect(:TRIVIA)
    end
  end

  describe "merge/2 collision detection" do
    test "rejects a fragment that redefines an existing (non-extension-point) name differently" do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@colliding_fragment)

      assert {:error, error} = GrammarCompose.merge(core, fragment)
      assert error.message =~ "collision"
      assert error.message =~ inspect(:INTEGER)
    end

    test "does not reject a fragment's identical redeclaration of a shared token" do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@time_series_like_fragment)

      assert {:ok, _merged} = GrammarCompose.merge(core, fragment)
    end

    test "does not reject two fragments both contributing to the same extension point" do
      core = parse!(@core_source, "priv/grammar.aether")
      time_series = parse!(@time_series_like_fragment, "time_series.aether")
      document = parse!(@document_like_fragment, "document.aether")

      assert {:ok, once_merged} = GrammarCompose.merge(core, time_series)
      assert {:ok, _twice_merged} = GrammarCompose.merge(once_merged, document)
    end
  end
end
