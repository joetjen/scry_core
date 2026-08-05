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
      # :ichor is runtime: false (correctly excluded from a real release,
      # §4 of impl_spec.md's grammar-composition design) -- but Dialyzer
      # respects that flag when auto-discovering PLT apps too, and
      # ScryCore.GrammarCompose's own typespecs genuinely reference
      # Aether.Grammar.t()/Ichor.TokenRefiner, so it has to be added
      # back explicitly here or every reference to an Ichor type reads
      # as unknown.
      dialyzer: [plt_add_apps: [:mix, :ichor]]
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
      # combinators. `ichor` itself never ships to production (grammar
      # composition and codegen happen at build time via a
      # `mix ichor.gen`-equivalent tooling, never via `use Ichor` at an
      # end consumer's own compile time) -- but scry_core is not an
      # ordinary consumer of Ichor, it's the library responsible for
      # driving composition itself (ScryCore.GrammarCompose,
      # Ichor.generate_from_grammar/2), so its own test suite genuinely
      # needs `ichor` (the compiler), not just `ichor_runtime`. Hence
      # `[:dev, :test]`, not just `:dev`. See impl_spec.md §4.
      {:ichor_runtime, "~> 0.2"},
      {:ichor, "~> 0.2", only: [:dev, :test], runtime: false},

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
