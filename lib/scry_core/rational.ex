defmodule ScryCore.Rational do
  @moduledoc """
  Exact rationals, per lang_spec.md §4 ("Numbers: exact rationals by
  default" -- a Lisp/Scheme-style numeric tower, not IEEE-754
  float-by-default). Only what a *literal* needs to construct: `new/2`
  (auto-reduced via GCD, a denominator of `1` collapsing to a plain
  `integer()` rather than a `%__MODULE__{}` -- so this struct only ever
  represents a genuinely non-integer exact value) and `compare/2`
  (exact, cross-multiplication-based -- no floating point anywhere in
  the comparison path).

  Deliberately not a full arithmetic type yet (`+ - * ** /` as a query
  expression, `sqrt`'s per-input exactness recovery, float-on-ingest
  conversion, lang_spec.md §4's "Inexact (float) coexistence" model) --
  nothing in `priv/grammar.aether` can construct or evaluate an
  arithmetic *expression* yet, only a `2/3`-shaped rational *literal*
  (`ScryCore.Actions`' `rational` rule, plain-integer numerator and
  denominator only). That's real future work, not an oversight.
  """

  @type t :: %__MODULE__{numerator: integer(), denominator: pos_integer()}

  @enforce_keys [:numerator, :denominator]
  defstruct [:numerator, :denominator]

  @doc """
  Builds the reduced exact-rational value of `numerator / denominator`
  -- auto-reduced via GCD (lang_spec.md §4), sign normalized onto the
  numerator, and collapsed to a plain `integer()` when the reduced
  denominator is `1` (also §4: "a denominator of `1` collapses to a
  plain integer"). Raises `ArithmeticError` for a zero denominator,
  matching `Kernel.div/2`'s own convention for the same condition.
  """
  @spec new(integer(), integer()) :: integer() | t()
  def new(_numerator, 0), do: raise(ArithmeticError, "rational literal with a zero denominator")

  def new(numerator, denominator) when is_integer(numerator) and is_integer(denominator) do
    sign = if denominator < 0, do: -1, else: 1
    numerator = sign * numerator
    denominator = sign * denominator
    gcd = Integer.gcd(numerator, denominator)

    case div(denominator, gcd) do
      1 ->
        div(numerator, gcd)

      reduced_denominator ->
        %__MODULE__{numerator: div(numerator, gcd), denominator: reduced_denominator}
    end
  end

  @doc """
  Exact three-way comparison between any mix of `t()` and plain
  `integer()` -- cross-multiplication (`an * bd` vs `bn * ad`), never a
  float conversion, so it stays exact regardless of magnitude.
  """
  @spec compare(integer() | t(), integer() | t()) :: :lt | :eq | :gt
  def compare(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)

    cond do
      an * bd < bn * ad -> :lt
      an * bd > bn * ad -> :gt
      true -> :eq
    end
  end

  defp parts(%__MODULE__{numerator: n, denominator: d}), do: {n, d}
  defp parts(n) when is_integer(n), do: {n, 1}
end
