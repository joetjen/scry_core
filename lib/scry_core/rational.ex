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

  `add/2`/`sub/2`/`mul/2`/`div/2`/`pow/2` close the four arithmetic
  operators lang_spec.md §5.10 lists (`+ - * /`, plus `**` for integer
  exponents) over the rationals -- every one of them just builds on
  `new/2`'s own construct-and-reduce, so the closure and collapse-to-
  integer properties `new/2` already documents apply automatically to
  every arithmetic result too, not separately re-derived per operator.
  Still deliberately incomplete: `sqrt`'s per-input exactness recovery
  and float-on-ingest conversion (lang_spec.md §4's "Inexact (float)
  coexistence" model) aren't here -- nothing in this codebase evaluates
  `sqrt` or ingests row data through a conversion step yet, so there's
  nothing real to build either against. That's future work, not an
  oversight.
  """

  # `div/2` is this module's own exact-rational division (lang_spec
  # §5.10), not `Kernel.div/2`'s integer division -- excepted here so
  # the two don't conflict; every internal use of *integer* division
  # (`new/2`'s own reduction step) calls `Kernel.div/2` explicitly.
  import Kernel, except: [div: 2]

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

    case Kernel.div(denominator, gcd) do
      1 ->
        Kernel.div(numerator, gcd)

      reduced_denominator ->
        %__MODULE__{numerator: Kernel.div(numerator, gcd), denominator: reduced_denominator}
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

  @doc "Exact addition, closed over the rationals -- `an/ad + bn/bd = (an*bd + bn*ad) / (ad*bd)`."
  @spec add(integer() | t(), integer() | t()) :: integer() | t()
  def add(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bd + bn * ad, ad * bd)
  end

  @doc "Exact subtraction, closed over the rationals."
  @spec sub(integer() | t(), integer() | t()) :: integer() | t()
  def sub(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bd - bn * ad, ad * bd)
  end

  @doc "Exact multiplication, closed over the rationals."
  @spec mul(integer() | t(), integer() | t()) :: integer() | t()
  def mul(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bn, ad * bd)
  end

  @doc """
  Exact division, closed over the rationals (lang_spec.md §5.10: "`/` =
  exact rational division"). Raises `ArithmeticError` for a zero
  divisor, via the same `new/2` zero-denominator guard every other
  construction path already goes through -- not a separate check here.
  """
  @spec div(integer() | t(), integer() | t()) :: integer() | t()
  def div(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bd, ad * bn)
  end

  @doc """
  Exact exponentiation with an **integer** exponent, positive, negative,
  or zero (lang_spec.md §5.10: "`**`(integer exponent)... closed over
  the rationals" -- the rationals aren't closed under an arbitrary
  rational exponent, e.g. `sqrt`, which is exactly why the exponent is
  constrained to integers here, not a limitation of this function
  alone). A negative exponent is the reciprocal of the positive one; any
  nonzero base to the power `0` is `1`, the ordinary convention.
  """
  @spec pow(integer() | t(), integer()) :: integer() | t()
  def pow(_base, 0), do: 1

  def pow(base, exponent) when is_integer(exponent) and exponent > 0 do
    Enum.reduce(2..exponent//1, base, fn _, acc -> mul(acc, base) end)
  end

  def pow(base, exponent) when is_integer(exponent) and exponent < 0 do
    div(1, pow(base, -exponent))
  end

  # A non-integer exponent (`2 ** (1/2)`, say -- syntactically valid per
  # `priv/grammar.aether`'s own `power` rule, which recurses through the
  # same `primary` any operand does, rational literals included) is a
  # real, foreseeable misuse worth a clear message for, not a bare
  # `FunctionClauseError` from the guards above quietly not matching.
  def pow(_base, exponent) do
    raise ArgumentError, "exponent must be an integer, got: #{inspect(exponent)}"
  end

  defp parts(%__MODULE__{numerator: n, denominator: d}), do: {n, d}
  defp parts(n) when is_integer(n), do: {n, 1}
end
