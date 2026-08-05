defmodule ScryCore.Grammar do
  @moduledoc """
  Compiles core's own `priv/grammar.aether` into a ready-to-run
  `%Aether.Grammar{}`. The real "`mix ichor.gen`-equivalent tooling"
  impl_spec.md §4 describes doesn't exist yet as an actual Mix compiler
  task, so `compile/0` parses and analyzes from source on every call
  instead of loading a pre-generated module. Fine for now: grammar
  composition (merging in a loaded kind's own fragment,
  `ScryCore.GrammarCompose`) doesn't have a build-time hook yet either,
  so this only ever compiles core alone. Revisit both together once the
  real Mix task exists.

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
  Parses and analyzes core's own grammar, recompiling from source every
  call (see this module's own moduledoc for why).
  """
  # grammar_path/0's only inputs are :code.priv_dir(:scry_core) (fixed
  # at compile time by the OTP application itself, never
  # runtime-supplied) and the hardcoded literal "grammar.aether" --
  # there is no user- or caller-controlled input anywhere in this path,
  # so directory traversal genuinely isn't reachable here. Low
  # confidence in Sobelow's own report, and this is why it's safe to
  # skip (`mix sobelow --skip`, see this project's own `mix.exs`).
  @sobelow_skip ["Traversal.FileModule"]
  @spec compile() :: {:ok, Aether.Grammar.t()} | {:error, term()}
  def compile do
    path = grammar_path()

    with {:ok, source} <- File.read(path),
         {:ok, grammar} <- Aether.Parser.parse(source, path) do
      Grammar.Analysis.run(grammar)
    end
  end

  @doc false
  @spec grammar_path() :: String.t()
  def grammar_path, do: Path.join(:code.priv_dir(:scry_core), "grammar.aether")
end
