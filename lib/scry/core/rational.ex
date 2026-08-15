defmodule Scry.Core.Rational do
  @moduledoc """
  Exact rationals ("Numbers: exact rationals by
  default" -- a Lisp/Scheme-style numeric tower, not IEEE-754
  float-by-default). Only what a *literal* needs to construct: `new/2`
  (auto-reduced via GCD, a denominator of `1` collapsing to a plain
  `integer()` rather than a `%__MODULE__{}` -- so this struct only ever
  represents a genuinely non-integer exact value) and `compare/2`
  (exact, cross-multiplication-based -- no floating point anywhere in
  the comparison path).

  `add/2`/`sub/2`/`mul/2`/`div/2`/`pow/2` close the four arithmetic
  operators (`+ - * /`, plus `**` for integer
  exponents) over the rationals -- every one of them builds on `new/2`'s
  own construct-and-reduce, so the closure and collapse-to-integer
  properties `new/2` already documents apply automatically to every
  arithmetic result too, not separately re-derived per operator. `add/2`/
  `sub/2`/`mul/2` each gain one exception: a leading clause for "both
  operands are already plain integers" skips `new/2` entirely, since an
  integer result there is *always* already in lowest terms (nothing for
  `Integer.gcd/2` to find) -- a real, measured cost at scale (aggregating
  `sum(...)` over many rows/groups is dominated by exactly this per-call
  overhead), not a style preference. `div/2` has no equivalent fast path
  -- `3/2` genuinely isn't an integer, so it always needs `new/2`'s own
  reduction to decide what the result actually is.

  **Inexact (float) coexistence.** `to_float/1`/
  `from_float/1` are the two conversion directions -- `from_float/1` via
  `Float.ratio/1` (stdlib), the exact rational value of an IEEE-754
  double, always exists and always bounded (a fixed-width mantissa has a
  fixed-size exact rational form), per the "conversion on
  ingest" framing. `add/2`/`sub/2`/`mul/2`/`div/2`/`pow/2` each gain a
  leading clause for "either operand is already a native `float()`" --
  the **contagion** rule, *"mixing exact and inexact in one
  operation yields inexact"*: the *other* operand converts to a float
  too (`to_float/1`), the whole operation happens in ordinary Kernel
  float arithmetic, and the result is a plain `float()`, never routed
  through `new/2` (which would silently make an inexact result exact
  again -- exactly what contagion forbids). `compare/2` is deliberately
  *not* contagion the same way -- a float argument there converts to
  *its own* exact value (`from_float/1`) before the existing exact
  cross-multiplication comparison, since a comparison result isn't a
  "value" contagion has anything to say about, and exact comparison is
  strictly more correct than comparing two lossy floats would be.

  Still deliberately incomplete: `sqrt`'s own per-input exactness
  recovery (exact only when both parts of a reduced
  `p/q` are perfect squares, inexact otherwise) isn't here -- nothing in
  this codebase evaluates `sqrt` yet, so there's nothing real to build
  that against. That's future work, not an oversight.
  """

  # `div/2` is this module's own exact-rational division,
  # not `Kernel.div/2`'s integer division -- excepted here so
  # the two don't conflict; every internal use of *integer* division
  # (`new/2`'s own reduction step) calls `Kernel.div/2` explicitly.
  import Kernel, except: [div: 2]

  @type t :: %__MODULE__{numerator: integer(), denominator: pos_integer()}

  @enforce_keys [:numerator, :denominator]
  defstruct [:numerator, :denominator]

  @doc """
  Builds the reduced exact-rational value of `numerator / denominator`
  -- auto-reduced via GCD, sign normalized onto the
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
  The exact rational value of a native `float()` ("conversion on
  ingest") -- `Float.ratio/1` (stdlib) always succeeds,
  always bounded, since an IEEE-754 double's fixed-width mantissa has a
  fixed-size exact rational form.
  """
  @spec from_float(float()) :: integer() | t()
  def from_float(f) when is_float(f) do
    {numerator, denominator} = Float.ratio(f)
    new(numerator, denominator)
  end

  @doc "The inexact `float()` value of an exact `t()`/`integer()` -- ordinary lossy division."
  @spec to_float(integer() | t() | float()) :: float()
  def to_float(f) when is_float(f), do: f
  def to_float(%__MODULE__{numerator: n, denominator: d}), do: n / d
  def to_float(n) when is_integer(n), do: n / 1

  @doc """
  Three-way comparison between any mix of `t()`, plain `integer()`, and
  `float()`. A `float()` argument converts to *its own* exact value
  first (`from_float/1`) -- comparison is deliberately not contagion the
  way arithmetic below is (see this module's own moduledoc) -- so the
  comparison itself always stays exact, cross-multiplication (`an * bd`
  vs `bn * ad`), never lossy float comparison.
  """
  @spec compare(integer() | t() | float(), integer() | t() | float()) :: :lt | :eq | :gt
  def compare(a, b) when is_float(a) or is_float(b) do
    compare(exactify(a), exactify(b))
  end

  def compare(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)

    cond do
      an * bd < bn * ad -> :lt
      an * bd > bn * ad -> :gt
      true -> :eq
    end
  end

  @doc """
  Addition. Exact and closed over the rationals for exact inputs
  (`an/ad + bn/bd = (an*bd + bn*ad) / (ad*bd)`) -- but contagion
  (this module's own moduledoc) applies the moment
  either operand is already an inexact `float()`: the result is a plain
  `float()` then, not routed through `new/2`.
  """
  @spec add(integer() | t() | float(), integer() | t() | float()) :: integer() | t() | float()
  def add(a, b) when is_float(a) or is_float(b), do: to_float(a) + to_float(b)

  # Two plain integers: `a/1 + b/1 = (a+b)/1`, always already in lowest
  # terms -- `Integer.gcd/2` and the rest of `new/2`'s own reduction
  # machinery can only ever confirm what's already true here, never
  # change the answer. A real, measured cost this fast path avoids:
  # aggregating `sum(...)` over plain-integer values at scale (a
  # `GROUP BY` with many distinct groups, one `add/2` call per row) is
  # dominated by exactly this per-call overhead, not by the executor's
  # own per-row dispatch -- confirmed directly (an isolated
  # microbenchmark, `Rational.add/2` vs. native `+`, ~2x), not assumed.
  def add(a, b) when is_integer(a) and is_integer(b), do: a + b

  def add(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bd + bn * ad, ad * bd)
  end

  @doc "Subtraction -- same contagion rule as `add/2`."
  @spec sub(integer() | t() | float(), integer() | t() | float()) :: integer() | t() | float()
  def sub(a, b) when is_float(a) or is_float(b), do: to_float(a) - to_float(b)

  # Same reasoning as `add/2`'s own integer fast path just above.
  def sub(a, b) when is_integer(a) and is_integer(b), do: a - b

  def sub(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bd - bn * ad, ad * bd)
  end

  @doc "Multiplication -- same contagion rule as `add/2`."
  @spec mul(integer() | t() | float(), integer() | t() | float()) :: integer() | t() | float()
  def mul(a, b) when is_float(a) or is_float(b), do: to_float(a) * to_float(b)

  # Same reasoning as `add/2`'s own integer fast path above.
  def mul(a, b) when is_integer(a) and is_integer(b), do: a * b

  def mul(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bn, ad * bd)
  end

  @doc """
  Division ("`/` = exact rational division") -- same
  contagion rule as `add/2`. Raises `ArithmeticError` for a zero
  divisor, via the same `new/2` zero-denominator guard every other exact
  construction path already goes through (a zero float divisor instead
  raises Kernel's own `ArithmeticError` for `/0.0`, the same class of
  error for the same reason) -- not a separate check here either way.
  """
  # No integer/integer fast path here, deliberately, unlike `add/2`/
  # `sub/2`/`mul/2` above: `3 / 2` is *not* an integer, so this always
  # genuinely needs `new/2`'s own GCD reduction to decide whether the
  # result collapses to a plain integer or stays a real `t()` -- there's
  # no case where the general path is doing unnecessary work.
  @spec div(integer() | t() | float(), integer() | t() | float()) :: integer() | t() | float()
  def div(a, b) when is_float(a) or is_float(b), do: to_float(a) / to_float(b)

  def div(a, b) do
    {an, ad} = parts(a)
    {bn, bd} = parts(b)
    new(an * bd, ad * bn)
  end

  defp exactify(f) when is_float(f), do: from_float(f)
  defp exactify(x), do: x

  @doc """
  Exponentiation with an **integer** exponent, positive, negative, or
  zero ("`**`(integer exponent)... closed over the
  rationals" -- the rationals aren't closed under an arbitrary rational
  exponent, e.g. `sqrt`, which is exactly why the exponent is
  constrained to integers here, not a limitation of this function
  alone; unrelated to contagion -- a `float()` base is just as
  constrained). A negative exponent is the reciprocal of the positive
  one; any nonzero base to the power `0` is `1` (or `1.0`, for a
  `float()` base -- preserving contagion downstream, not silently
  collapsing an inexact value back to an exact one). Positive/negative
  exponents already inherit contagion for free through `mul/2`/`div/2`
  below (a `float()` base makes every intermediate product a `float()`
  too), so only the `0` case needs its own explicit branch.
  """
  @spec pow(integer() | t() | float(), integer()) :: integer() | t() | float()
  def pow(base, 0) when is_float(base), do: 1.0
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
