defmodule Scry.Core.Grammar.SigilLexeme do
  @moduledoc """
  Arbitrary-delimiter regex-sigil scanning (lang_spec.md §3/§4:
  `@tag<delim>...<delim>`, "any delimiter") -- Aether's `@native`/
  `Ichor.CustomLexeme` escape hatch (`priv/grammar.aether`'s own
  `SIGIL` comment has the "why a plain token pattern can't do this"
  reasoning: requiring the *same* character back at the close is a
  backreference, which neither Aether's native token primitives nor its
  own regex-sigil desugaring support).

  `scan/3` only recognizes the shape and finds where the sigil ends --
  it does *not* interpret the tag or compile a regex; that stays exactly
  where it already was, in `Scry.Core.Actions.handle_token/3`, generalized
  to read the delimiter character from the matched text itself instead
  of assuming `/`. Returning `nil` as the fourth element (no capture
  override) is what makes this possible: the *whole* matched text
  (delimiters included) still reaches `handle_token/3` as an ordinary
  `{:token, :SIGIL, text}`, completely unlike `Ichor`'s own heredoc
  example (which overrides with `{:text, body}` specifically because it
  wants `handle_token/3` bypassed) -- confirmed empirically, via a
  scratch grammar, that a `nil` override does fall through to the
  ordinary per-token path before relying on it here.

  Delimiter is a single byte, not a grapheme -- matches every realistic
  case (`/ | # ~ !`, anything ASCII) and needs no Unicode-awareness:
  a multi-byte UTF-8 character's own bytes can never collide with a
  single ASCII delimiter byte, by UTF-8's own design, so scanning
  byte-by-byte for the delimiter byte alone is safe over UTF-8 content.
  Not restricted to non-alphanumeric delimiters -- lang_spec doesn't
  call for that restriction, and the grammar-stays-permissive posture
  this codebase uses throughout doesn't add one speculatively.
  """

  @doc """
  `input` is the *remaining* source suffix (`c:Ichor.CustomLexeme.scan/3`'s
  own contract) -- returns `{:ok, text, rest, nil}` on a match (`text <>
  rest == input`), `:fail` otherwise. `\\<delim>` inside the content is
  the one recognized escape (lets the delimiter character appear
  literally without ending the sigil) -- deliberately not more general
  escape handling, matching `priv/grammar.aether`'s own prior
  `SIGIL_ESCAPE` reasoning: sigil content is regex syntax, where
  `\\d`/`\\s`/etc. are meaningful to the regex engine itself and must
  reach it completely unmodified.
  """
  @spec scan(binary(), term(), map()) :: {:ok, binary(), binary(), nil} | :fail
  def scan(input, _context, _rule_matchers) do
    with {:ok, delim, after_delim} <- match_prefix(input),
         {:ok, rest} <- consume_until_delim(after_delim, delim) do
      text = binary_part(input, 0, byte_size(input) - byte_size(rest))
      {:ok, text, rest, nil}
    else
      :fail -> :fail
    end
  end

  # Single-letter tag only, not `[[:alpha:]]+` -- lang_spec gives
  # exactly one concrete tag (`r`); an arbitrary-length tag name ahead
  # of a second real one existing is exactly the kind of "design for a
  # hypothetical future requirement" this codebase otherwise avoids
  # (the same reasoning the token this replaces already had).
  defp match_prefix(<<"@", tag_char, delim_char, rest::binary>>)
       when tag_char in ?a..?z or tag_char in ?A..?Z do
    {:ok, delim_char, rest}
  end

  defp match_prefix(_), do: :fail

  defp consume_until_delim(<<"\\", c, rest::binary>>, delim) when c == delim,
    do: consume_until_delim(rest, delim)

  defp consume_until_delim(<<c, rest::binary>>, delim) when c == delim, do: {:ok, rest}
  defp consume_until_delim(<<_c, rest::binary>>, delim), do: consume_until_delim(rest, delim)
  defp consume_until_delim(<<>>, _delim), do: :fail
end
