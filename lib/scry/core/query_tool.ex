defmodule Scry.Core.QueryTool do
  @moduledoc """
  The config-driven resolution/execution/formatting logic behind `mix
  scry.query`/`mix scry.iex` -- kept as a plain module, independent of
  `Mix.Task`, so it's directly unit-testable and so both tasks share
  exactly one copy of this logic instead of duplicating it (as the two
  tasks this replaces, in `scry_test_core`, used to).

  ## Why this lives in `scry_core`, and how a kind/engine package "plugs in"

  `scry_core` can never depend on any `scry_<kind>` or `scry_engine_
  <driver>` package -- they depend on *it*, so hardcoding a parser or a
  `%{"name" => backend}` map here the way `scry_test_core`'s own
  now-removed tasks did would be backwards. Two ways a downstream
  package's own capability could reach a task living here were
  considered; only one is compatible with this project's own already-
  established rules:

  Auto-detecting what's installed and composing/dispatching dynamically
  at task-invocation time was **tried once already, for grammar
  composition specifically, and explicitly abandoned** (impl_spec.md
  §4/§8): any module touching `Ichor.*` (the grammar-composition
  toolchain) has to live somewhere Mix compiles unconditionally, which
  broke `scry_core`-as-a-dependency compilation for a consumer with no
  interest in grammar composition at all. The restated policy since:
  "which kind libraries are loaded is a build-time, not runtime,
  property." Auto-detecting installed backends here would be the same
  shape of mistake, not a neutral choice.

  So: **config-driven wiring**, the same shape Ecto's own Mix tasks use
  (`config :my_app, ecto_repos: [...]`) -- the *root project* actually
  running `mix scry.query`/`mix scry.iex` (which always has its own
  real `config/config.exs` in play, config and all, whether that
  project is an application depending on `scry_core` or a library like
  `scry_test_core` being run directly) declares which parser module and
  which named `{engine, conn}`-producing functions are available:

  ```elixir
  # config/config.exs
  config :scry_core, :query_tool,
    parser: Scry.TimeSeries,                        # optional, defaults to Scry.Core; must expose parse/1
    executor: {Scry.TimeSeries.Executor, :run},      # optional, defaults to {Scry.Core.Executor, :run}
    default: "postgres",                             # optional, only needed when more than one backend is configured
    backends: %{
      "in_memory" => {Scry.Test.Core.Conn, :in_memory},
      "postgres" => {Scry.Test.Core.Conn, :postgres}
    }
  ```

  A `scry_<kind>` package "enhances the core" by way of its own already-
  established convention, unchanged: it ships its own composed
  `<Kind>.parse/1` (e.g. `Scry.TimeSeries.parse/1`, built once at that
  package's own dev time via its checked-in grammar-composition
  generator script -- nothing new needed there). A project depending on
  it just points `parser:` at that module. **A kind whose queries need
  more than `Scry.Core.Executor` understands (`Scry.TimeSeries`'s own
  `LAST <duration> OF <field>`, say -- meaningless to `Scry.Core.
  Executor` on its own, that package's own moduledoc has the full "why
  a separate executor" reasoning) also configures `executor:`,
  `{module, function}`, called as `function(query, engine, conn)`** --
  found needed, not designed speculatively ahead of a real kind package
  actually requiring it: `scry_time_series`'s own `Scry.TimeSeries.
  Executor.run/5` has two further, defaulted arguments (`params`,
  `now`) beyond the three this module ever calls it with, which Elixir
  itself resolves to a real, callable `run/3` -- no shim needed on
  either side for the common case. A `scry_engine_<driver>` package
  "becomes usable" the same way -- a project depending on it registers
  a named backend in `backends:` pointing at whatever function opens a
  real connection and returns `{engine_module, conn}` (`{module,
  function}`, called with no arguments -- wrap it in your own zero-arity
  helper if it needs real arguments, e.g. connection options).
  """

  @typedoc "A parsed-and-materialized row, ready to print."
  @type row :: %{optional(String.t()) => term()}

  @doc """
  Resolves which module's own `parse/1` to use -- `cli_value` (e.g. a
  `--parser` flag's string value) wins if given and loadable; else the
  configured `:parser`; else `Scry.Core` (always loadable, since this
  module lives in the same package).
  """
  @spec resolve_parser(String.t() | nil) :: {:ok, module()} | {:error, String.t()}
  def resolve_parser(nil) do
    case Keyword.get(config(), :parser) do
      nil -> {:ok, Scry.Core}
      module when is_atom(module) -> {:ok, module}
    end
  end

  def resolve_parser(cli_value) when is_binary(cli_value) do
    module = Module.concat([cli_value])

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, "--parser #{cli_value}: no such module could be loaded"}
    end
  end

  @doc """
  Resolves which configured backend to use, and actually calls it --
  `cli_name` (a `--backend` flag's string value) wins if given; else
  the configured `:default`; else the sole configured backend, if
  there's exactly one; else a clear error listing the real configured
  names (never a stale hardcoded list). Zero backends configured at all
  is its own case, with an error that doubles as the onboarding
  instructions for this module's own config shape.
  """
  @spec resolve_backend(String.t() | nil) :: {:ok, {module(), term()}} | {:error, String.t()}
  def resolve_backend(cli_name) do
    backends = Keyword.get(config(), :backends, %{})
    name = cli_name || Keyword.get(config(), :default) || sole_backend_name(backends)

    case name do
      nil -> {:error, missing_backend_error(backends)}
      name -> fetch_backend(backends, name)
    end
  end

  defp sole_backend_name(backends) when map_size(backends) == 1,
    do: backends |> Map.keys() |> hd()

  defp sole_backend_name(_backends), do: nil

  defp fetch_backend(backends, name) do
    case Map.fetch(backends, name) do
      {:ok, {module, function}} -> {:ok, apply(module, function, [])}
      :error -> {:error, unknown_backend_error(name, backends)}
    end
  end

  defp missing_backend_error(backends) when map_size(backends) == 0 do
    """
    no backends configured. Add to your config/config.exs:

        config :scry_core, :query_tool,
          backends: %{"my_backend" => {MyApp.SomeModule, :my_conn_fun}}

    `my_conn_fun/0` should return `{engine_module, conn}`, ready for
    `Scry.Core.Executor.run/3`. See `Scry.Core.QueryTool`'s own
    moduledoc for the full shape, including an optional `default:` and
    `parser:`.
    """
  end

  defp missing_backend_error(backends) do
    "multiple backends configured (#{backend_names(backends)}) -- pass --backend NAME, " <>
      "or set `default: \"NAME\"` in `config :scry_core, :query_tool`"
  end

  defp unknown_backend_error(name, backends) do
    "unknown --backend #{name} (configured: #{backend_names(backends)})"
  end

  defp backend_names(backends), do: backends |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp config, do: Application.get_env(:scry_core, :query_tool, [])

  @doc """
  Parses `source` with `parser`'s own `parse/1`, then delegates to
  `execute/2`. For a caller that has already parsed (e.g. `mix
  scry.iex`'s own REPL loop, which must parse first to tell "needs
  another line" apart from "a real error"), call `execute/2` directly
  instead of paying to parse the same source twice.
  """
  @spec run(String.t(), module(), {module(), term()}) :: {:ok, [row()]} | {:error, term()}
  def run(source, parser, {engine, conn}) do
    with {:ok, query} <- parser.parse(source) do
      execute(query, {engine, conn})
    end
  end

  @doc """
  Runs an already-parsed `query` against `{engine, conn}` via the
  configured `:executor` (defaulting to `Scry.Core.Executor.run/3`),
  and materializes the full result -- a plain list of plain, human-
  readable maps (any `Scry.Core.Row` normalized via `Row.to_map/1`,
  since a real pushdown engine's own direct path may return one),
  never a lazy `Scry.Core.Cursor.t()`. A `Scry.Core.Executor.QueryError`
  (raised lazily, only once a caller actually pulls far enough to reach
  the offending row) is caught and folded back into the same
  `{:error, reason}` shape a parse failure or an engine's own decline
  already use -- true of any kind-specific executor too, since every
  one of them still raises this same exception for the same reason
  (they all delegate the underlying row-processing machinery to
  `Scry.Core.QueryOps`, which is where this exception actually
  originates).
  """
  @spec execute(term(), {module(), term()}) :: {:ok, [row()]} | {:error, term()}
  def execute(query, {engine, conn}) do
    {executor_module, executor_function} = resolve_executor()

    with {:ok, cursor} <- apply(executor_module, executor_function, [query, engine, conn]) do
      materialize(cursor)
    end
  end

  defp resolve_executor do
    case Keyword.get(config(), :executor) do
      nil -> {Scry.Core.Executor, :run}
      {module, function} when is_atom(module) and is_atom(function) -> {module, function}
    end
  end

  defp materialize(cursor) do
    {:ok, cursor |> Scry.Core.Cursor.to_list() |> Enum.map(&to_plain_row/1)}
  rescue
    e in Scry.Core.Executor.QueryError -> {:error, e.reason}
  end

  defp to_plain_row(%Scry.Core.Row{} = row), do: Scry.Core.Row.to_map(row)
  defp to_plain_row(row), do: row

  @doc """
  Formats an error for printing -- a parse failure is one (or a list
  of) `%Ichor.Error{}`, formatted via its own `format/1` rather than a
  raw struct dump; anything else (an execution-time error, an unknown/
  missing-backend message already a plain string) falls back to
  `inspect/1` for a term or is returned as-is for a string.
  """
  @spec format_error(term()) :: String.t()
  def format_error(%Ichor.Error{} = error), do: Ichor.Error.format(error)

  def format_error(errors) when is_list(errors) do
    Enum.map_join(errors, "\n", fn
      %Ichor.Error{} = error -> Ichor.Error.format(error)
      other -> inspect(other)
    end)
  end

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(other), do: inspect(other)
end
