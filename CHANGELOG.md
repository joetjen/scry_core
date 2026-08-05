# Changelog

## [Unreleased]

### Added

- Initial project scaffold: `mix.exs` (app `:scry_core`, `ichor`/`ichor_runtime` deps per impl_spec.md §4's grammar-composition design), `.credo.exs`/`.formatter.exs`/`.tool-versions`, minimal `lib/scry_core.ex`, `test/test_helper.exs`.
- `priv/grammar.aether`: a deliberately bounded Phase 1 core grammar (comments, identifiers/dot-path, a small literal set, `select`/`where`/`and`/`or`/`not`/comparisons/`in`, and one EP1(a) extension point) proving the core/variant composition architecture against a real parser for the first time. See the file's own header for the full list of what's covered and what's deferred.
- `ScryCore.Grammar.KeywordRefiner`: case-insensitive keyword reclassification via `@refine`, standing in for Aether's `@keywords` (which does not pick up `@case_insensitive`, confirmed empirically).
- `ScryCore.GrammarCompose.merge/2`: the core+fragment grammar merge from impl_spec.md §4 -- collision-checked (structurally-identical shared redeclarations, e.g. `TRIVIA`, are not collisions), with a proactive check that a fragment's `@skip` matches core's own (a fragment defaulting to a different skip token bakes an unmatchable reference into its own rules once merged -- found by actually running the composition, not assumed from reading Ichor's source).

- `ScryCore.Query`: the shared struct both Scry front ends (text grammar, and the not-yet-implemented Elixir-native builder, impl_spec.md §7) converge on.
- `ScryCore.Actions`: turns `priv/grammar.aether`'s parse tree into `%ScryCore.Query{}` -- covers everything the current Phase 1 grammar can produce (`select`/`where`/boolean logic/comparisons/`in`/dotted paths/projected fields), with core-only handling for the EP1(a) extension point (stored unexamined under `variant.select_ep1a`, a stand-in for real composed-Actions dispatch once a second real kind exists to compose against).

### Fixed

- `mix.exs`: `ichor` is now `only: [:dev, :test]`, not just `:dev` -- scry_core's own test suite drives grammar composition directly (unlike an ordinary consuming application, which only needs `ichor` at its own dev-time `mix ichor.gen` step) and genuinely needs the compiler present under `MIX_ENV=test`.
- `mix.exs`: added `:ichor` to `dialyzer: [plt_add_apps: ...]` -- Dialyzer's PLT auto-discovery respects `runtime: false` the same way a real release does, so it silently excluded `ichor` (and every `Aether.Grammar.t()`/`Ichor.TokenRefiner` type `ScryCore.GrammarCompose` references) without this.
- `priv/grammar.aether`: `where:where_clause?` and `items:literal_list?` renamed to bare `where_clause?`/`literal_list?` -- explicitly naming an optional (`?`) *rule* reference was found to produce a second, spurious raw-text capture alongside the properly-dispatched one under the rule's own implicit self-capture name (the same pathology `select_ep1a?` was already written to avoid, now confirmed general rather than specific to that one case). Does not affect optional *token* references (`neg:KW_NOT?` is unaffected).
