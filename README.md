# scry_core

The core grammar/compiler library for Scry —
lexical structure, literals, core keyword/operator reference, core block
structure, type system, and the EP1/EP2 extension-point declarations every
kind library (`scry_relational`, `scry_graph`, `scry_time_series`, ...)
composes against. No backend kind of its own.

Source: <https://github.com/joetjen/scry_core>.

## Installation

```elixir
def deps do
  [
    {:scry_core, "~> 1.0"}
  ]
end
```

## Command-line tools

`scry_core` ships `mix scry.query`/`mix scry.iex` (an interactive prompt) --
available to any project depending on `scry_core`, directly or indirectly,
once that project's own `config/config.exs` wires up at least one backend:

```elixir
config :scry_core, :query_tool,
  parser: Scry.TimeSeries,                    # optional, defaults to Scry.Core
  executor: {Scry.TimeSeries.Executor, :run},  # optional, defaults to {Scry.Core.Executor, :run}
  default: "postgres",                        # optional, needed only with >1 backend
  backends: %{
    "in_memory" => {MyApp.Conn, :in_memory},
    "postgres" => {MyApp.Conn, :postgres}
  }
```

See `Scry.Core.QueryTool`'s own moduledoc for the full config reference, and
either Mix task's own moduledoc for usage and flags.

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_core>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_core/) on every push to `main`.
