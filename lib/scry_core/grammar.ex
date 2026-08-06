defmodule ScryCore.Grammar do
  @moduledoc """
  Compiles core's own `priv/grammar.aether` into a ready-to-run
  `%Aether.Grammar{}`. The real "`mix ichor.gen`-equivalent tooling"
  impl_spec.md §4 describes (a Mix compiler step that auto-detects a
  build's own dependency tree and merges in every loaded kind's own
  fragment) doesn't exist yet, so both functions below parse and
  analyze from source on every call instead of loading a pre-generated
  module. `compile_unanalyzed/0` is what makes composition possible
  today without that automatic step -- a `scry_<kind>` package calls it
  directly, merges its own fragment in via `ScryCore.GrammarCompose.
  merge/2`, and analyzes the merged result itself (`ScryTimeSeries.
  Grammar`, in the `scry_time_series` package, is the first real one
  that does this). Revisit once the real Mix task exists.

  Uses `:code.priv_dir/1`, not a path relative to the current working
  directory -- the only way this resolves correctly both from
  `scry_core`'s own test suite *and* from another package (like
  `scry_test_engine_core`) depending on `scry_core` as an ordinary
  compiled dependency, where the working directory is that package's
  own root, not `scry_core`'s.
  """

  # Registered (not a bare `@sobelow_skip [...]`) so the Elixir
  # compiler treats it as a real, persisted attribute rather than
  # flagging it "set but never used" -- which `mix compile
  # --warnings-as-errors` (part of `mix precommit`) would otherwise
  # turn into a hard failure. Sobelow itself doesn't need this
  # (`Sobelow.Parse` reads `@sobelow_skip` straight out of the raw
  # source text, not compiled attribute metadata); this is purely to
  # keep the two tools from fighting each other.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  Parses core's own grammar (recompiling from source every call, see
  this module's own moduledoc for why) *without* running `Grammar.
  Analysis` -- the shape `ScryCore.GrammarCompose.merge/2` itself
  requires (its own moduledoc: "not yet run through `Grammar.
  Analysis`"), since analysis expects every `RuleRef` to already
  resolve, which an EP1/EP2 extension point deliberately doesn't until
  a kind's own fragment is merged in. A `scry_<kind>` package composing
  against core (`impl_spec.md` §4) calls this instead of `compile/0`,
  merges in its own parsed-but-unanalyzed fragment, and only then runs
  `Grammar.Analysis` on the merged result -- `compile/0` below is
  exactly that same read-then-parse step, plus analysis, for the
  no-fragment (core-alone) case.
  """
  # grammar_path/0's only inputs are :code.priv_dir(:scry_core) (fixed
  # at compile time by the OTP application itself, never
  # runtime-supplied) and the hardcoded literal "grammar.aether" --
  # there is no user- or caller-controlled input anywhere in this path,
  # so directory traversal genuinely isn't reachable here. Low
  # confidence in Sobelow's own report, and this is why it's safe to
  # skip (`mix sobelow --skip`, see this project's own `mix.exs`).
  @sobelow_skip ["Traversal.FileModule"]
  @spec compile_unanalyzed() :: {:ok, Aether.Grammar.t()} | {:error, term()}
  def compile_unanalyzed do
    path = grammar_path()

    with {:ok, source} <- File.read(path) do
      Aether.Parser.parse(source, path)
    end
  end

  @doc """
  Parses and analyzes core's own grammar (`compile_unanalyzed/0` +
  `Grammar.Analysis.run/1`) -- the core-alone case; a kind package
  composing its own fragment in calls `compile_unanalyzed/0` directly
  instead (see its own moduledoc).
  """
  @spec compile() :: {:ok, Aether.Grammar.t()} | {:error, term()}
  def compile do
    with {:ok, grammar} <- compile_unanalyzed() do
      Grammar.Analysis.run(grammar)
    end
  end

  @doc false
  @spec grammar_path() :: String.t()
  def grammar_path, do: Path.join(:code.priv_dir(:scry_core), "grammar.aether")
end
