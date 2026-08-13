defmodule Scry.Core.Grammar.BodyListSep do
  @moduledoc """
  `priv/grammar.aether`'s own `body_list_sep` rule -- lang_spec.md §6:
  comma required between two body items sharing a physical line,
  optional (a line break suffices) when each is on its own line.

  Rule-position `@native` (`guides/aether/AETHER.md`'s "at rule
  position" section), not ordinary grammar composition -- found
  necessary, not chosen for style, after `~`-suppressed right-recursion
  alone (this file's own comment on `body_list_tail` has the fuller
  story) turned out not to survive a real leak: `body_item`'s own
  trailing optional/repeated lookaheads (`field_body_item`'s
  `if_clause?`, `path`'s own dotted-segment `*`) unconditionally splice
  past any trivia sitting there while checking for a construct that
  usually isn't present, *whether or not it's found* -- so by the time
  `body_list_sep` gets control, the position may already sit past the
  very newline it needs to see, with no trace of it left in any
  grammar-level capture.

  `match/4` sidesteps this by reading the compiled token `stream`
  directly (`c:Ichor.CustomRule.match/4`'s own contract: `stream`/`pos`,
  the same ones any ordinary rule matcher works over) rather than
  trusting ordinary rule composition to have preserved anything:

    1. Scan *forward* from `pos` through any `TRIVIA`/`COMMA` tokens
       actually sitting there -- the ordinary, non-leaked case, where
       nothing upstream has looked past this span yet.
    2. Scan *backward* from wherever that leaves off through any
       `TRIVIA`/`COMMA` tokens immediately preceding it -- recovers the
       leaked case, since whatever `body_item` spliced past is still a
       real, distinct token in the stream; only the parser's *position*
       moved beyond it, not the token itself.

  Either direction finding a `COMMA`, or a `TRIVIA` token whose own text
  contains a newline, is sufficient. Always succeeds (`{:ok, ...}`,
  never `:fail`) -- this rule's job is only to *classify* whatever
  separator is or isn't there, not to reject a bad one itself; `status`
  is `"ok"` or `"missing_comma"`, resolved into a real `{:error, ...}`
  by `Scry.Core.Actions`' own `body_list_sep` handler, the same
  "grammar overmatches, an Actions callback decides validity" split
  `Scry.Core.Grammar.BlockCommentLexeme` already uses. Never advances
  *past* real content -- the forward scan only ever consumes
  `TRIVIA`/`COMMA` tokens, stopping the instant it sees anything else,
  so the next `body_item` still starts exactly where it should.
  """

  @doc """
  `stream` is the full compiled token tuple, `pos` the current index
  into it (`c:Ichor.CustomRule.match/4`'s own contract) -- returns
  `{:ok, new_pos, {:rule, :body_list_sep, [status: {:text, status}]}}`,
  never `:fail`. `_context`/`_rule_matchers` are unused: this scan needs
  neither the previous top-level form's context (no mid-file grammar
  mutation the way Prolog's `op/3` example needs) nor a callback into
  any other rule (it reads `stream` directly, never re-parses).
  """
  @spec match(tuple(), non_neg_integer(), term(), map()) ::
          {:ok, non_neg_integer(), Ichor.Capture.node_t()}
  def match(stream, pos, _context, _rule_matchers) do
    {new_pos, fwd_comma?, fwd_newline?} = scan_forward(stream, pos, false, false)
    {back_comma?, back_newline?} = scan_backward(stream, new_pos, false, false)

    status =
      if fwd_comma? or back_comma? or fwd_newline? or back_newline?,
        do: "ok",
        else: "missing_comma"

    {:ok, new_pos, {:rule, :body_list_sep, [status: {:text, status}]}}
  end

  defp scan_forward(stream, pos, comma?, newline?) do
    case token_at(stream, pos) do
      {:TRIVIA, text} -> scan_forward(stream, pos + 1, comma?, newline? or newline_in?(text))
      {:COMMA, _text} -> scan_forward(stream, pos + 1, true, newline?)
      _other -> {pos, comma?, newline?}
    end
  end

  defp scan_backward(_stream, 0, comma?, newline?), do: {comma?, newline?}

  defp scan_backward(stream, pos, comma?, newline?) do
    case token_at(stream, pos - 1) do
      {:TRIVIA, text} -> scan_backward(stream, pos - 1, comma?, newline? or newline_in?(text))
      {:COMMA, _text} -> scan_backward(stream, pos - 1, true, newline?)
      _other -> {comma?, newline?}
    end
  end

  defp token_at(stream, pos) when pos >= 0 and pos < tuple_size(stream) do
    token = elem(stream, pos)
    {token.name, token.text}
  end

  defp token_at(_stream, _pos), do: nil

  defp newline_in?(text), do: String.contains?(text, "\n")
end
