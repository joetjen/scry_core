defmodule ScryCore.Grammar.BlockCommentLexeme do
  @moduledoc """
  `;` block comments (lang_spec.md §3: "Valid only immediately before a
  block-opening keyword (`select`, `via`, `with`, `fragment`, `type`, or
  an EP1(b)-contributed keyword); consumes through its own matching `}`
  via `{`/`}` depth counting. Unterminated block comment is a compile
  error.") -- comments out an *entire* upcoming declaration, not a
  self-delimited `;{...}` body of its own. Genuinely a context-free, not
  regular, construct (nested brace-depth counting), so it needs
  Aether's `@native`/`Ichor.CustomLexeme` escape hatch the same way
  `ScryCore.Grammar.SigilLexeme` does -- see that module's own
  moduledoc for the mechanics this one shares (`nil` capture override,
  `scan/3`'s own contract).

  `@keywords` is core's own four (`select`/`with`/`fragment`/`type`) --
  `via` (the graph variant's own EP1(b) block-opening keyword) and any
  other EP1(b)-contributed keyword are deliberately not included, since
  no kind fragment exists in this codebase yet to contribute one
  (matches this codebase's own "no real kind exists yet" posture
  elsewhere, e.g. `body_item_ep1 := NEVER`). Revisit when a real
  variant is composed in.

  The scan has four phases, each verified independently via scratch
  grammar before landing this shape (nested `SELECT`s, both string
  delimiters, a multiline string, and a trailing `#`-comment all
  containing a literal `{`/`}` that must *not* affect the count):

    1. Match the leading `;`.
    2. Skip ordinary trivia (space/`#`-comment), then match one of
       `@keywords`, case-insensitively, not immediately followed by an
       identifier-continuing character (so `;selection` doesn't wrongly
       match `select`).
    3. Scan forward to the construct's own first *real* `{` -- skipping
       over any string/multiline-string literal and `#`-comment
       encountered along the way, so a `{`/`}` inside either is never
       mistaken for the body's own opening.
    4. Depth-count from there (same string/comment skipping) to the
       *matching* `}` -- the comment's own span ends there, not one
       character further; anything after (a trailing `#`-comment, say)
       is ordinary trivia the grammar's own `TRIVIA` token skips
       separately, not this scanner's concern.

  A known, narrow limitation, not handled: a regex sigil's own `{n,m}`
  quantifier syntax (`@r/a{2,3}/`) inside a commented-out construct
  isn't recognized as sigil content, so its own braces *would* affect
  the depth count. Rare in practice (a regex quantifier nested inside a
  commented-out declaration) and not worth the real complexity of
  replicating `ScryCore.Grammar.SigilLexeme`'s own arbitrary-delimiter
  recognition here too, for now -- a real, documented gap, not an
  oversight.
  """

  @keywords ~w(select with fragment type)

  @doc """
  `input` is the *remaining* source suffix (`c:Ichor.CustomLexeme.scan/3`'s
  own contract) -- returns `{:ok, text, rest, nil}` on a match (`text <>
  rest == input`), `:fail` when `;` isn't immediately (modulo trivia)
  followed by a recognized keyword, or when no matching `}` is ever
  found (surfaces as an ordinary lexer-stage parse error further up the
  pipeline -- lang_spec's own "unterminated block comment is a compile
  error").
  """
  @spec scan(binary(), term(), map()) :: {:ok, binary(), binary(), nil} | :fail
  def scan(input, _context, _rule_matchers) do
    with {:ok, after_semi} <- match_semi(input),
         {:ok, after_keyword} <- match_keyword(after_semi),
         {:ok, after_open_brace} <- skip_to_first_brace(after_keyword),
         {:ok, rest} <- skip_body(after_open_brace, 1) do
      text = binary_part(input, 0, byte_size(input) - byte_size(rest))
      {:ok, text, rest, nil}
    else
      :fail -> :fail
    end
  end

  defp match_semi(<<";", rest::binary>>), do: {:ok, rest}
  defp match_semi(_), do: :fail

  defp match_keyword(input), do: input |> skip_trivia() |> match_keyword_name(@keywords)

  defp match_keyword_name(_input, []), do: :fail

  defp match_keyword_name(input, [kw | rest_kws]) do
    len = byte_size(kw)

    case input do
      <<candidate::binary-size(len), after_kw::binary>> ->
        if String.downcase(candidate) == kw and not ident_char?(after_kw) do
          {:ok, after_kw}
        else
          match_keyword_name(input, rest_kws)
        end

      _ ->
        match_keyword_name(input, rest_kws)
    end
  end

  defp ident_char?(<<c, _::binary>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
    do: true

  defp ident_char?(_), do: false

  defp skip_trivia(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: skip_trivia(rest)
  defp skip_trivia(<<"#", rest::binary>>), do: skip_trivia(skip_to_eol(rest))
  defp skip_trivia(input), do: input

  defp skip_to_eol(<<"\n", rest::binary>>), do: rest
  defp skip_to_eol(<<_c, rest::binary>>), do: skip_to_eol(rest)
  defp skip_to_eol(<<>>), do: <<>>

  # `"""` tried before a lone `"` -- the same maximal-munch
  # disambiguation `MULTILINE_STRING`/`STRING` themselves rely on in
  # priv/grammar.aether, replicated here since this scanner does its
  # own re-lexing rather than calling back into the tokenizer.
  defp skip_to_first_brace(<<"{", rest::binary>>), do: {:ok, rest}

  defp skip_to_first_brace(<<"\"\"\"", rest::binary>>) do
    with {:ok, remaining} <- skip_delimited(rest, "\"\"\""), do: skip_to_first_brace(remaining)
  end

  defp skip_to_first_brace(<<"\"", rest::binary>>) do
    with {:ok, remaining} <- skip_delimited(rest, "\""), do: skip_to_first_brace(remaining)
  end

  defp skip_to_first_brace(<<"'", rest::binary>>) do
    with {:ok, remaining} <- skip_delimited(rest, "'"), do: skip_to_first_brace(remaining)
  end

  defp skip_to_first_brace(<<"#", rest::binary>>), do: skip_to_first_brace(skip_to_eol(rest))
  defp skip_to_first_brace(<<_c, rest::binary>>), do: skip_to_first_brace(rest)
  defp skip_to_first_brace(<<>>), do: :fail

  defp skip_body(input, 0), do: {:ok, input}

  defp skip_body(<<"\"\"\"", rest::binary>>, depth) do
    with {:ok, remaining} <- skip_delimited(rest, "\"\"\""), do: skip_body(remaining, depth)
  end

  defp skip_body(<<"\"", rest::binary>>, depth) do
    with {:ok, remaining} <- skip_delimited(rest, "\""), do: skip_body(remaining, depth)
  end

  defp skip_body(<<"'", rest::binary>>, depth) do
    with {:ok, remaining} <- skip_delimited(rest, "'"), do: skip_body(remaining, depth)
  end

  defp skip_body(<<"#", rest::binary>>, depth), do: skip_body(skip_to_eol(rest), depth)
  defp skip_body(<<"{", rest::binary>>, depth), do: skip_body(rest, depth + 1)
  defp skip_body(<<"}", rest::binary>>, depth), do: skip_body(rest, depth - 1)
  defp skip_body(<<_c, rest::binary>>, depth), do: skip_body(rest, depth)
  defp skip_body(<<>>, _depth), do: :fail

  # `\<char>` skipped as a pair, unconditionally, without needing to
  # know which escape it is -- matches `STRING`/`MULTILINE_STRING`'s own
  # `ESCAPE | !"<delim>" .` shape in priv/grammar.aether for the same
  # reason: this is skipping, not decoding, so treating any
  # backslash-prefixed pair as "doesn't end the string" is sufficient
  # (including `\uXXXX`, where the hex digits after `u` just fall
  # through the generic clause below as ordinary characters).
  defp skip_delimited(input, delim), do: do_skip_delimited(input, delim, byte_size(delim))

  defp do_skip_delimited(<<"\\", _escaped, rest::binary>>, delim, delim_size),
    do: do_skip_delimited(rest, delim, delim_size)

  defp do_skip_delimited(input, delim, delim_size) do
    case input do
      <<^delim::binary-size(delim_size), rest::binary>> -> {:ok, rest}
      <<_c, rest::binary>> -> do_skip_delimited(rest, delim, delim_size)
      <<>> -> :fail
    end
  end
end
