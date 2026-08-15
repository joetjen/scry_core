defmodule Scry.Core.MixProject do
  use Mix.Project

  @version "1.0.1"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_core,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Core",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      # `:ichor` needs to be listed explicitly here now that it's
      # `runtime: false` (only [:dev, :test]) -- dialyxir's default PLT
      # scan draws on the compiled app's own `:applications` list, which
      # a `runtime: false` dependency is deliberately excluded from
      # (it's not meant to be part of the running application), even
      # though it's still genuinely present and compiled in this
      # (`:test`) env, and `Scry.Core.Grammar`/`Scry.Core.GrammarCompose`
      # still reference its types (`Aether.Grammar.t/0`, ...) directly.
      # `:iex` -- `mix scry.iex`'s own `IEx.started?/0` check needs
      # Dialyzer's own PLT to know the function exists. Deliberately
      # *not* also in `extra_applications` below -- confirmed
      # empirically (in `scry_test_core`, the package this task moved
      # here from) that starting the `:iex` OTP application (which
      # declaring it there would trigger, via `Mix.Task.run(
      # "app.start")`) flips `IEx.started?/0` to `true` all by itself,
      # with no real interactive session involved at all, defeating
      # the whole point of checking it. `IEx`'s own module is already
      # on the code path without starting its application (part of
      # the Elixir installation itself), so no `extra_applications`
      # entry is needed for the call to actually work at runtime.
      dialyzer: [plt_add_apps: [:mix, :ichor, :iex], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Scry.Core.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === ICHOR (grammar compiler) ===
      # `ichor_runtime` is the real runtime dependency -- capture dispatch
      # (Ichor.Actions), error formatting, the compiled Tokenizer/Parser
      # combinators.
      #
      # `ichor` was originally unscoped here (a real, non-`only:` dep):
      # `Scry.Core.Grammar`/`Scry.Core.GrammarCompose` used to call Ichor's
      # "raw pipeline" (Aether.Parser + Grammar.Analysis + Grammar.VM)
      # directly at runtime, on every `Scry.Core.parse/1` call, making
      # `ichor` a genuine compile-time requirement of scry_core's own
      # `lib/` -- confirmed empirically at the time: even with `ichor`
      # also declared directly in a downstream package's own deps, `mix
      # compile` for scry_core-as-a-dependency still failed to resolve
      # `Aether.Grammar`, because Mix does not propagate an `only:`-
      # scoped dependency transitively -- compiling scry_core as a
      # dependency only ever draws on scry_core's own declared
      # dependency graph. Fixed: `Scry.Core.parse/1` now runs queries
      # through `Scry.Core.Grammar.Compiled`, a checked-in, pre-generated
      # module (`priv/gen/generate_compiled_grammar.exs` is its
      # generator, run by hand, never automatically -- see `Scry.Core.
      # Grammar`'s own moduledoc for why an automatic Mix compiler step
      # can't solve this, only a script that's never itself compiled as
      # part of anyone's `lib/` can). The generated module only calls
      # `ichor_runtime`, never `ichor` -- so `ichor` genuinely is
      # build-time-only now, back to `only: [:dev, :test]`, matching
      # `ichor`'s own documented recommendation for exactly this case.
      {:ichor_runtime, "~> 0.2"},
      {:ichor, "~> 0.2", only: [:dev, :test], runtime: false},

      # `DXN`/`DXNB` name Dextrin's own Data eXchange
      # Notation format -- a real, unscoped runtime dependency, not
      # only: [:dev, :test], since `dxn(<field>)`/`dxnb(<field>)`
      # (§5.8's own escape-hatch casts) call `Dextrin.decode/2`/
      # `decode_binary/2` directly at query-execution time, the same
      # relationship `json(<field>)` has to Erlang/OTP's own built-in
      # `:json` module (no dependency needed there, since that one's
      #
      # `path:`, not a `~> 0.1` Hex requirement, temporarily: the
      # published `dextrin` 0.1.2 still pulls in `decimal` 2.4.1, which
      # carries a real, confirmed MEDIUM-severity DoS advisory (EEF-
      # CVE-2026-32686, `mix hex.audit`) -- already fixed on `dextrin`'s
      # own `develop` branch (`decimal` bumped to `~> 3.0`), just not
      # released to Hex yet. Switch this back to a real `~> 0.1`
      # version requirement once that release ships -- tracked here,
      # not silently left as a permanent path dependency.
      # in the standard library).
      {:dextrin, path: "../dextrin"},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  #
  # No automated check here for `lib/scry/core/grammar/compiled.ex`
  # being stale relative to `priv/grammar.aether` -- tried a regenerate-
  # and-diff step first, but the codegen backend iterates `%Aether.
  # Grammar{}`'s own `tokens`/`rules` maps to emit functions, and Elixir
  # map iteration order isn't stable across VM boots (randomized hash
  # seeding), so a byte-diff between two separately-generated copies of
  # the *same* grammar spuriously fails. Matches `mix ichor.gen`'s own
  # documented, deliberate posture (`ichor/lib/mix/tasks/ichor.gen.ex`'s
  # own moduledoc): "there's no automatic staleness check between the
  # checked-in file and its source grammar" -- `grammar_parity_test.exs`
  # and the generated module's own banner (rerun the command, don't
  # hand-edit) are the safety net instead.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        # `--skip`: honors `@sobelow_skip` annotations on specific
        # functions (AGENTS.md: a low-confidence finding needs a
        # targeted, justified skip, never a blanket suppression) --
        # without this flag Sobelow ignores the annotation entirely and
        # reports the finding anyway.
        "sobelow --skip",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "The core grammar/compiler library for Scry -- lexical structure, literals, core " <>
      "keyword/operator reference, block structure, type system, and the EP1/EP2 " <>
      "extension-point declarations every kind library composes against."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_core"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_core",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
