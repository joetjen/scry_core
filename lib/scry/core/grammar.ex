defmodule Scry.Core.Grammar do
  @moduledoc """
  Parses (and, via `compile/0`, analyzes) core's own `priv/grammar.
  aether` from source. **Not** the production parse path anymore --
  `Scry.Core.parse/1` calls the checked-in, pre-generated `Scry.Core.
  Grammar.Compiled` (`priv/gen/generate_compiled_grammar.exs` is its
  generator; re-run that script after editing `priv/grammar.aether`,
  never hand-edit the generated file). Both functions here stay, for
  two real callers that still legitimately want the from-source,
  uncompiled path: `compile_unanalyzed/0` is what `Scry.Core.
  GrammarCompose.merge/2` itself requires (an unanalyzed `%Aether.
  Grammar{}` to merge a kind fragment into -- `ScryTimeSeries.Grammar`,
  in the `scry_time_series` package, calls this directly), and both
  this module's own generator script and `test/scry/core/actions_test.
  exs`/`grammar_compose_test.exs` (testing `Scry.Core.Actions`'
  individual `handle_rule` clauses against the cheap interpreted
  `Grammar.VM` path, deliberately, rather than round-tripping through
  codegen for every unit test) use `compile/0`.

  Why the production path is a *manually-run* generator script, not an
  automatic Mix compiler (`compilers: [...]`) auto-detecting the build's
  own dependency tree the way impl_spec.md §4 originally sketched: any
  module that calls `Ichor.*` (parsing, analysis, codegen) has to live
  somewhere Mix compiles it, and *any* file under a package's own
  `elixirc_paths` -- a `Mix.Task.Compiler` included, since it has to be
  a real discoverable module to be invoked via `compilers: [...]` at
  all -- gets compiled unconditionally whenever that package is built,
  including as someone else's dependency. `mix.exs`'s own deps comment
  has the empirical finding this runs into: an `only: [:dev, :test]`
  dependency of *this* package is dropped by Mix whenever `scry_core`
  is compiled as someone else's dependency, regardless of the
  downstream package's own env. A plain script run via `mix run
  priv/gen/generate_compiled_grammar.exs`, only ever invoked in this
  package's own top-level dev context, is never compiled as part of
  anyone's build at all -- this mirrors `mix ichor.gen`'s own
  documented, recommended path for exactly this problem
  (`ichor/lib/ichor.ex`'s own moduledoc: "the only one of the three
  [ways to run a grammar] where `ichor` itself never needs to be
  present at runtime, `mix release` builds included").

  Uses `:code.priv_dir/1`, not a path relative to the current working
  directory -- the only way this resolves correctly both from
  `scry_core`'s own test suite *and* from another package (like
  `scry_test_engine_core`) depending on `scry_core` as an ordinary
  compiled dependency, where the working directory is that package's
  own root, not `scry_core`'s.
  """

  # `Aether.Parser.parse/2`/`Grammar.Analysis.run/1` (below) are
  # genuinely undefined when this module compiles as a dependency of a
  # package that never declares `ichor` itself (its own `only: [:dev,
  # :test]` scoping in *this* package's `mix.exs` deliberately isn't
  # propagated transitively -- see that file's own deps comment) --
  # expected, not a bug: neither function is ever actually *called* by
  # such a consumer (`Scry.Core.parse/1`'s own production path doesn't
  # reach either one anymore either way). Without this, every such
  # consumer's own `mix compile`/any Mix task that triggers one prints
  # two scary-looking "is undefined" warnings for something that's
  # never a real problem -- `@compile {:no_warn_undefined, ...}` is
  # Elixir's own documented mechanism for exactly this (`Module`'s own
  # moduledoc; the standard library uses it the same way, e.g. `Regex`'s
  # own `{:re, :import, 1}`), not a suppression hack.
  @compile {:no_warn_undefined, {Aether.Parser, :parse, 2}}
  @compile {:no_warn_undefined, {Grammar.Analysis, :run, 1}}

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
  Analysis` -- the shape `Scry.Core.GrammarCompose.merge/2` itself
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
  `Grammar.Analysis.run/1`) -- the core-alone case. Used by this
  module's own generator script and by `Scry.Core.Actions`' own unit
  tests (`Grammar.VM.run/4` against the result), not by `Scry.Core.
  parse/1` itself anymore (see this module's own moduledoc); a kind
  package composing its own fragment in calls `compile_unanalyzed/0`
  directly instead.
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
