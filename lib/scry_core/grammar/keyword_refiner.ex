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

  @behaviour Ichor.TokenRefiner

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
    "required" => :KW_REQUIRED
  }

  @impl true
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
