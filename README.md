# scry_core

The core grammar/compiler library for [Scry](https://github.com/joetjen/scry) —
lexical structure, literals, core keyword/operator reference, core block
structure, type system, and the EP1/EP2 extension-point declarations every
kind library (`scry_relational`, `scry_graph`, `scry_time_series`, ...)
composes against. No backend kind of its own — see `scry`'s
[`lang_spec.md`](https://github.com/joetjen/scry/blob/main/lang_spec.md) §2
and `impl_spec.md` §1–§2 for the full design.

Source: <https://github.com/joetjen/scry_core>. Specs live in the separate
[`scry`](https://github.com/joetjen/scry) repository. Implementation has not
started yet.

## Installation

```elixir
def deps do
  [
    {:scry_core, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_core>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_core/) on every push to `main`.
