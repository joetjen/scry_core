defmodule Mix.Tasks.Scry.Query do
  @shortdoc "Runs a Scry query against a configured backend"

  @moduledoc """
  Runs a query and prints the resulting rows -- for trying the query
  language out, or spot-checking a specific query's own behavior,
  without writing any Elixir code first. Available to any project that
  depends on `scry_core`, directly or indirectly, once that project's
  own `config/config.exs` wires up at least one backend (see below) --
  Mix's own task discovery scans every dependency's compiled tasks
  regardless of `only:`/`runtime:` scoping, so no extra registration
  step is needed for the task itself to show up.

      $ mix scry.query "SELECT users WHERE age > 18 { name }"
      $ mix scry.query --file path/to/query.scry
      $ mix scry.query --backend postgres "SELECT users WHERE id = 1 { name }"
      $ mix scry.query --parser Scry.TimeSeries "..."

  Exactly one of a query-text argument or `--file` is required; giving
  both, or neither, is a usage error. Several positional arguments
  (unquoted query text, split by the shell) are joined back together
  with a single space -- quoting the whole query is still the more
  reliable habit (`{`/`}` and other punctuation can confuse some
  shells when left unquoted), but this covers the simple case too.

  ## Configuring parsers and backends

  `scry_core` can't hardcode which `scry_<kind>` grammar or which
  `scry_engine_<driver>` connection to use -- it depends on neither, by
  design (they depend on it). Instead, the *root project* actually
  running this task declares both in its own config:

  ```elixir
  # config/config.exs
  config :scry_core, :query_tool,
    parser: Scry.TimeSeries,              # optional, defaults to Scry.Core
    default: "postgres",                  # optional, needed only with >1 backend
    backends: %{
      "in_memory" => {MyApp.Conn, :in_memory},
      "postgres" => {MyApp.Conn, :postgres}
    }
  ```

  `--backend NAME` overrides the configured default for a single
  invocation; `--parser MODULE` (a module name string, e.g.
  `Scry.TimeSeries`) overrides the configured parser the same way. See
  `Scry.Core.QueryTool`'s own moduledoc for the full config reference,
  including the exact error you'll see with nothing configured yet.
  """

  use Mix.Task

  alias Scry.Core.QueryTool

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {switches, args} =
      OptionParser.parse!(argv, strict: [file: :string, backend: :string, parser: :string])

    with {:ok, source} <- fetch_query_source(switches, args),
         {:ok, parser} <- QueryTool.resolve_parser(switches[:parser]),
         {:ok, backend} <- QueryTool.resolve_backend(switches[:backend]),
         {:ok, rows} <- QueryTool.run(source, parser, backend) do
      IO.inspect(rows, pretty: true, limit: :infinity)
    else
      {:error, reason} -> Mix.raise("scry.query failed: #{QueryTool.format_error(reason)}")
    end
  end

  defp fetch_query_source(switches, args) do
    case {switches[:file], args} do
      {nil, []} ->
        {:error, "give either a query as an argument or --file PATH"}

      {nil, args} ->
        {:ok, Enum.join(args, " ")}

      {path, []} ->
        read_file(path)

      {_path, _args} ->
        {:error, "give either a query as an argument or --file PATH, not both"}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end
end
