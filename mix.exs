defmodule ScryCore.MixProject do
  use Mix.Project

  @version "0.1.0"

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
      name: "ScryCore",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
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
      # `ichor` is, in principle, a build-time-only tool (grammar
      # composition and codegen belong at build time via a
      # `mix ichor.gen`-equivalent Mix compiler task, never via `use
      # Ichor` at an end consumer's own compile time -- see impl_spec.md
      # §4) and was originally scoped `only: [:dev, :test]` on that
      # basis. That scoping turned out to be unusable: `ScryCore.Grammar`
      # and `ScryCore.GrammarCompose` call Ichor's "raw pipeline"
      # (Aether.Parser + Grammar.Analysis + Grammar.VM) directly rather
      # than working from a pre-generated module, so `ichor` is a genuine
      # compile-time requirement of scry_core's own `lib/` -- not just of
      # its test suite. Confirmed empirically: even after also declaring
      # `ichor` directly in a downstream package's own deps, `mix
      # compile` for scry_core-as-a-dependency still failed to resolve
      # `Aether.Grammar` -- Mix does not propagate an `only:`-scoped
      # dependency transitively, and compiling scry_core as a dependency
      # only ever draws on scry_core's own declared dependency graph.
      # Real (unscoped) for now; the fix that lets this go back to
      # `only: [:dev, :test]` is building the actual Mix compiler task,
      # tracked as a confirmed-blocking item in impl_spec.md's Open
      # Implementation Risks.
      {:ichor_runtime, "~> 0.2"},
      {:ichor, "~> 0.2"},

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
