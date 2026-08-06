defmodule ScryCore.GrammarComposeTest do
  use ExUnit.Case, async: true

  alias ScryCore.GrammarCompose

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

  # `@root document` now (priv/grammar.aether's own `document` comment) --
  # every real query text parses as `fragment_decl* select`, not `select`
  # alone. None of the tests below are actually about FRAGMENT/`document`
  # itself (that's ScryCore.FragmentResolverTest's job); they're
  # exercising GrammarCompose/extension-point mechanics that all happen
  # to live inside `select`, so this just unwraps the one extra layer of
  # node the new root always wraps around it, uniformly.
  defp parse_select!(grammar, source) do
    {:ok, %Ichor.Node{rule: :document, captures: %{select: select_node}}} =
      Grammar.VM.run(grammar, source, NoActions, nil)

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
      # `tail` sits under `*` (a repeated capture), so it's always a
      # list -- same rule already established for path's own `tail`.
      assert [%Ichor.Node{rule: :body_item_ep1, captures: via}] = body.tail
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
