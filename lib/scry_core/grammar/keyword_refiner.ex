defmodule ScryCore.Grammar.KeywordRefiner do
  @moduledoc """
  Case-insensitive reclassification for core's structural keywords
  (lang_spec.md §3: "Keywords are case-insensitive"). Aether's own
  `@keywords` sugar does an exact, case-sensitive match against the
  token's raw text (`Grammar.Lexer.apply_refiner/3`) -- `@case_insensitive`
  does not extend to it, confirmed empirically while building
  priv/grammar.aether (see impl_spec.md's Ichor-investigation history for
  the general pattern this follows). This is `@refine`'s escape hatch:
  the same table `@keywords` would otherwise take, looked up against the
  downcased text instead of the raw one.
  """

  # `Ichor.TokenRefiner` is genuinely undefined when this module
  # compiles as a dependency of a package that never declares `ichor`
  # itself -- expected, not a bug, same root cause `ScryCore.Grammar`'s
  # own `@compile {:no_warn_undefined, ...}` comment documents.
  # `no_warn_undefined` doesn't reach a `@behaviour` declaration itself
  # (a different compiler check than the plain-remote-call one it
  # covers) or the `@impl true` below, which has nothing to verify
  # against once the behaviour isn't declared -- `Code.ensure_loaded?/1`
  # (evaluated at compile time, an established Elixir idiom for exactly
  # this "declare a behaviour only when its module is actually
  # available" case) is the real fix: declares the behaviour (and
  # `@impl`'s own check below) only when `ichor`'s genuinely present,
  # silent no-op otherwise. `refine/4`'s own runtime dispatch (`Grammar.
  # Lexer.apply_refiner/3` calling it directly by name) is entirely
  # unaffected either way -- `@behaviour`/`@impl` are compile-time-only,
  # never consulted at runtime.
  @ichor_token_refiner_loaded? Code.ensure_loaded?(Ichor.TokenRefiner)

  if @ichor_token_refiner_loaded? do
    @behaviour Ichor.TokenRefiner
  end

  @keywords %{
    "select" => :KW_SELECT,
    "where" => :KW_WHERE,
    "and" => :KW_AND,
    "or" => :KW_OR,
    "not" => :KW_NOT,
    "in" => :KW_IN,
    "nil" => :KW_NIL,
    "true" => :KW_TRUE,
    "false" => :KW_FALSE,
    "group" => :KW_GROUP,
    "by" => :KW_BY,
    "having" => :KW_HAVING,
    "distinct" => :KW_DISTINCT,
    "order" => :KW_ORDER,
    "limit" => :KW_LIMIT,
    "offset" => :KW_OFFSET,
    "desc" => :KW_DESC,
    "asc" => :KW_ASC,
    "required" => :KW_REQUIRED,
    "if" => :KW_IF,
    "when" => :KW_WHEN,
    "then" => :KW_THEN,
    "else" => :KW_ELSE,
    "fragment" => :KW_FRAGMENT,
    "with" => :KW_WITH,
    "union" => :KW_UNION,
    "all" => :KW_ALL,
    "intersect" => :KW_INTERSECT,
    "except" => :KW_EXCEPT,
    "over" => :KW_OVER,
    "partition" => :KW_PARTITION,
    "rows" => :KW_ROWS,
    "between" => :KW_BETWEEN,
    "preceding" => :KW_PRECEDING,
    "following" => :KW_FOLLOWING,
    "current" => :KW_CURRENT,
    "row" => :KW_ROW,
    "unbounded" => :KW_UNBOUNDED,
    "type" => :KW_TYPE,
    "rollup" => :KW_ROLLUP,
    "cube" => :KW_CUBE
  }

  if @ichor_token_refiner_loaded? do
    @impl true
  end

  def refine(raw_name, raw_text, _pos, _preceding) do
    # Unlike @keywords' own table-lookup path (which can short-circuit to
    # a bare `nil` capture meaning "no override"), Grammar.Lexer always
    # wraps a `:custom` refiner's returned value in `{:text, value}` --
    # so returning `nil` here would become a real override *to* nil, not
    # a no-op. Returning `raw_text` unchanged is what "no override"
    # actually means for this refiner kind.
    case Map.fetch(@keywords, String.downcase(raw_text)) do
      {:ok, new_name} -> {:ok, new_name, raw_text}
      :error -> {:ok, raw_name, raw_text}
    end
  end
end
