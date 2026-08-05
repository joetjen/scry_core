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

  Scaffolding only, no implementation yet.
  """
end
