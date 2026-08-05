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
  @well_formed_fragment """
  @grammar "fake_time_series_fragment"
  @root select_ep1a
  @case_insensitive
  @skip TRIVIA

  ; must match core's own skip token exactly (name and definition) --
  ; discarded at merge time in favor of core's, but required locally to
  ; satisfy Aether's own eager per-file @skip validation.
  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  select_ep1a := KW_LAST value:NUMBER

  KW_LAST := "last"
  """

  @mismatched_skip_fragment """
  @grammar "fake_bad_fragment"
  @root select_ep1a

  select_ep1a := KW_LAST value:NUMBER

  KW_LAST := "last"
  """

  @colliding_fragment """
  @grammar "fake_colliding_fragment"
  @root select_ep1a
  @case_insensitive
  @skip TRIVIA

  COMMENT := "#" (!"\\n" .)*
  TRIVIA  := (SPACE | COMMENT)*

  select_ep1a := KW_LAST value:NUMBER

  ; collides with core's own NUMBER (a different shape: hex digits, not
  ; decimal) -- must be rejected, not silently overwritten.
  NUMBER := HEX+
  KW_LAST := "last"
  """

  defp parse!(source, file \\ "test.aether") do
    {:ok, grammar} = Aether.Parser.parse(source, file)
    grammar
  end

  describe "core alone" do
    test "parses cleanly (extension points are valid dangling references at parse time)" do
      assert %Aether.Grammar{} = parse!(@core_source, "priv/grammar.aether")
    end

    test "fails Grammar.Analysis on its own -- select_ep1a is genuinely unfilled" do
      core = parse!(@core_source, "priv/grammar.aether")

      assert {:error, errors} = Grammar.Analysis.run(core)
      assert Enum.any?(errors, &(&1.message =~ "select_ep1a"))
    end
  end

  describe "merge/2 with a correctly-authored fragment" do
    setup do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@well_formed_fragment)
      {:ok, merged} = GrammarCompose.merge(core, fragment)
      %{merged: merged}
    end

    test "produces a grammar that passes Grammar.Analysis", %{merged: merged} do
      assert {:ok, _analyzed} = Grammar.Analysis.run(merged)
    end

    test "parses a query exercising both core and the extension point", %{merged: merged} do
      {:ok, analyzed} = Grammar.Analysis.run(merged)

      assert {:ok, %Ichor.Node{rule: :select, captures: captures}} =
               Grammar.VM.run(analyzed, ~s(SELECT metric last 5 { name }), NoActions, nil)

      assert %Ichor.Node{rule: :path, captures: %{head: "metric"}} = captures.source
      assert %Ichor.Node{rule: :select_ep1a, captures: ep1a} = captures.select_ep1a
      assert ep1a.value == "5"
      assert Map.fetch!(ep1a, :KW_LAST) == "last"
    end

    test "the extension-point keyword is case-insensitive, matching core's own keywords", %{
      merged: merged
    } do
      {:ok, analyzed} = Grammar.Analysis.run(merged)

      assert {:ok, %Ichor.Node{rule: :select}} =
               Grammar.VM.run(analyzed, ~s(select metric LAST 5 { name }), NoActions, nil)
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
    test "rejects a fragment that redefines an existing name differently" do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@colliding_fragment)

      assert {:error, error} = GrammarCompose.merge(core, fragment)
      assert error.message =~ "collision"
      assert error.message =~ inspect(:NUMBER)
    end

    test "does not reject a fragment's identical redeclaration of a shared token" do
      core = parse!(@core_source, "priv/grammar.aether")
      fragment = parse!(@well_formed_fragment)

      assert {:ok, _merged} = GrammarCompose.merge(core, fragment)
    end
  end
end
