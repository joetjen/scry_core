defmodule ScryCore do
  @moduledoc """
  The core grammar/compiler library for [Scry](https://github.com/joetjen/scry).

  Owns the kind-agnostic grammar (lexical structure, literals, core
  keyword/operator reference, core block structure, type system, core
  extended constructs), the EP1/EP2 extension-point declarations a kind
  library's own grammar fragment composes against, and the shared
  execution scaffold every kind's engine behaviour builds on top of. See
  `scry`'s `lang_spec.md` §2–§9 and `impl_spec.md` §1–§2 for the full
  design this implements.

  `parse/1` is the intended entry point for anything outside this
  package (`scry_test_engine_core`'s own integration tests, eventually
  a real adapter's) -- `ScryCore.Grammar`/`ScryCore.Actions` are public
  too, but composing them by hand is exactly the friction this function
  exists to avoid.
  """

  alias ScryCore.Query

  @doc """
  Parses `source` (Scry query text) into a `%ScryCore.Query{}`, using
  core's own grammar and `ScryCore.Actions`. Core-only -- no kind's
  grammar fragment is merged in (`ScryCore.GrammarCompose` exists, but
  nothing calls it here yet), so a query using a kind-specific
  extension point parses only as far as core's own "always fails"
  default for it allows.
  """
  @spec parse(String.t()) :: {:ok, Query.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    with {:ok, grammar} <- ScryCore.Grammar.compile() do
      Grammar.VM.run(grammar, source, ScryCore.Actions, nil)
    end
  end
end
