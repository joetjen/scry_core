defmodule Mix.Tasks.Scry.Iex do
  @shortdoc "Starts an interactive Scry query prompt against a configured backend"

  @moduledoc """
  An interactive, `iex`-like prompt for trying Scry queries -- no need
  to write out a full `mix scry.query "..."` invocation per query, or
  a `.exs` script. Available to any project depending on `scry_core`,
  directly or indirectly, the same way `mix scry.query` is -- see that
  task's own moduledoc, and `Scry.Core.QueryTool`'s, for the full
  config-driven parser/backend story this task shares with it.

      $ mix scry.iex
      scry> SELECT users
      ...>   WHERE age > 18
      ...>   { name }
      [%{"name" => "Alice"}, ...]
      scry>

  `--backend NAME`/`--parser MODULE` pick which configured backend and
  parser serve every query for the whole session, overriding the
  configured `:default`/`:parser` the same way `mix scry.query`'s own
  flags do.

  A query is only run once it parses -- pressing Enter mid-query (a
  still-incomplete `SELECT ... { ... }`, say) switches the prompt to
  `...>` and keeps accumulating lines rather than erroring immediately,
  the same "don't judge it until it's whole" posture `iex` itself has
  for an unfinished expression.

  **Up/Down arrow history, for real**: run it as `iex -S mix scry.iex`
  instead of plain `mix scry.iex`. Verified directly (a real pty, not
  assumed): the Up/Down/Left/Right line editing and history recall
  every terminal user expects isn't something this task implements --
  it's OTP's own interactive-shell group leader (`group`/`edlin`, the
  exact machinery `iex`'s own expression history already runs on),
  which is only attached to stdin under an actual interactive Erlang
  shell. Plain `mix scry.iex` boots the VM with `-noshell` (no group
  leader, no editing at all -- an arrow key lands as a literal `^[[A`
  escape sequence, confirmed empirically, not guessed), while `iex -S
  mix scry.iex` boots a real `iex` session first (full editing/history
  active) and then runs this task's own loop *inside* it -- an ordinary
  process under that same group leader gets the exact same treatment
  `iex`'s own prompt does, with zero code of this module's own
  involved. Plain `mix scry.iex` prints a one-line note about this at
  startup (gated on `IEx.started?/0` being `false`, so the note itself
  disappears once run the `iex -S mix scry.iex` way); everything else
  about this task works identically either way.

  One real limitation, worth stating rather than papering over: the
  default `Scry.Core` grammar (and any `scry_<kind>` grammar built the
  same way) is a plain backtracking PEG parser (`Ichor`), with no
  incremental/error-recovery parse mode to explain *why* a parse
  failed -- unlike `Code.string_to_quoted/2`'s own dedicated
  `TokenMissingError`, which is exactly how `iex` itself tells "needs
  one more line" apart from "wrong, full stop" (confirmed empirically:
  `Scry.Core.parse("SELECT users")` and `Scry.Core.parse("NOT A REAL
  QUERY")` return the *identical* positionless `%Ichor.Error{message:
  "input does not match :document"}`, nothing to tell them apart by).
  So this prompt doesn't try to guess -- it never shows a parse error
  while the buffer might still be added to; a blank line forces the
  buffer through as it stands and prints whatever comes back, a real
  result or the real error, then starts over at `scry>`. Ctrl+D (EOF
  on stdin) exits.
  """

  use Mix.Task

  alias Scry.Core.QueryTool

  @primary_prompt "scry> "
  @continuation_prompt "...> "

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {switches, _args} = OptionParser.parse!(argv, strict: [backend: :string, parser: :string])

    with {:ok, parser} <- QueryTool.resolve_parser(switches[:parser]),
         {:ok, backend} <- QueryTool.resolve_backend(switches[:backend]) do
      maybe_hint_about_history()
      loop("", parser, backend)
    else
      {:error, reason} -> Mix.raise("scry.iex: #{QueryTool.format_error(reason)}")
    end
  end

  defp maybe_hint_about_history do
    unless IEx.started?() do
      IO.puts(
        "(no arrow-key history here -- run `iex -S mix scry.iex` instead of `mix scry.iex` for that)"
      )
    end
  end

  defp loop(buffer, parser, backend) do
    prompt = if buffer == "", do: @primary_prompt, else: @continuation_prompt

    case IO.gets(prompt) do
      :eof -> IO.puts("")
      {:error, reason} -> Mix.raise("scry.iex: #{inspect(reason)}")
      line -> handle_line(buffer, String.trim_trailing(line, "\n"), parser, backend)
    end
  end

  defp handle_line(buffer, line, parser, backend) do
    blank? = String.trim(line) == ""

    cond do
      buffer == "" and blank? -> loop("", parser, backend)
      blank? -> attempt(buffer, parser, backend, force: true)
      buffer == "" -> attempt(line, parser, backend, force: false)
      true -> attempt(buffer <> "\n" <> line, parser, backend, force: false)
    end
  end

  defp attempt(buffer, parser, backend, force: force?) do
    case parser.parse(buffer) do
      {:ok, query} ->
        execute(query, backend)
        loop("", parser, backend)

      {:error, reason} when force? ->
        IO.puts(QueryTool.format_error(reason))
        loop("", parser, backend)

      {:error, _reason} ->
        loop(buffer, parser, backend)
    end
  end

  defp execute(query, backend) do
    case QueryTool.execute(query, backend) do
      {:ok, rows} -> IO.inspect(rows, pretty: true, limit: :infinity)
      {:error, reason} -> IO.puts(QueryTool.format_error(reason))
    end
  end
end
