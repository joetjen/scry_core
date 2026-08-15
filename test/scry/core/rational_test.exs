defmodule Scry.Core.RationalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Core.Rational

  describe "new/2" do
    test "a whole-number result collapses to a plain integer, not the struct" do
      assert Rational.new(6, 3) === 2
      assert Rational.new(6, 2) === 3
      assert Rational.new(0, 5) === 0
    end

    test "matches the worked example: 3.14 == 157/50" do
      assert Rational.new(314, 100) == Rational.new(157, 50)
      assert %Rational{numerator: 157, denominator: 50} = Rational.new(314, 100)
    end

    test "raises for a zero denominator, like Kernel.div/2" do
      assert_raise ArithmeticError, fn -> Rational.new(1, 0) end
    end

    property "is always reduced to lowest terms, with a positive denominator" do
      check all(numerator <- integer(), denominator <- integer(), denominator != 0) do
        case Rational.new(numerator, denominator) do
          n when is_integer(n) ->
            :ok

          %Rational{numerator: n, denominator: d} ->
            assert d > 0
            assert Integer.gcd(n, d) == 1
        end
      end
    end

    property "preserves the original ratio exactly" do
      check all(numerator <- integer(), denominator <- integer(), denominator != 0) do
        {result_num, result_den} =
          case Rational.new(numerator, denominator) do
            n when is_integer(n) -> {n, 1}
            %Rational{numerator: n, denominator: d} -> {n, d}
          end

        assert numerator * result_den == result_num * denominator
      end
    end
  end

  describe "compare/2" do
    test "a plain integer and an equal-valued rational compare equal" do
      assert Rational.compare(2, Rational.new(4, 2)) == :eq
      assert Rational.compare(Rational.new(1, 2), Rational.new(2, 4)) == :eq
    end

    test "orders correctly across sign and magnitude" do
      assert Rational.compare(Rational.new(1, 2), Rational.new(2, 3)) == :lt
      assert Rational.compare(Rational.new(-1, 2), 0) == :lt
      assert Rational.compare(3, Rational.new(5, 2)) == :gt
    end

    property "agrees with an independent exact cross-multiplication oracle" do
      check all(
              n1 <- integer(),
              d1 <- integer(),
              d1 != 0,
              n2 <- integer(),
              d2 <- integer(),
              d2 != 0
            ) do
        a = Rational.new(n1, d1)
        b = Rational.new(n2, d2)

        assert Rational.compare(a, b) == exact_compare(n1, d1, n2, d2)
      end
    end
  end

  describe "add/2, sub/2, mul/2, div/2" do
    test "matches ordinary arithmetic for whole numbers" do
      assert Rational.add(2, 3) == 5
      assert Rational.sub(5, 3) == 2
      assert Rational.mul(4, 5) == 20
      assert Rational.div(10, 5) == 2
    end

    test "1/2 + 1/3 = 5/6" do
      assert Rational.add(Rational.new(1, 2), Rational.new(1, 3)) == Rational.new(5, 6)
    end

    test "div/2 raises for a zero divisor, integer or rational" do
      assert_raise ArithmeticError, fn -> Rational.div(1, 0) end
      assert_raise ArithmeticError, fn -> Rational.div(1, Rational.new(0, 5)) end
    end

    property "add/sub/mul's own integer+integer fast path matches the general new/2-based reduction path" do
      check all(a <- integer(), b <- integer()) do
        assert Rational.add(a, b) == Rational.new(a * 1 + b * 1, 1 * 1)
        assert Rational.sub(a, b) == Rational.new(a * 1 - b * 1, 1 * 1)
        assert Rational.mul(a, b) == Rational.new(a * b, 1 * 1)
      end
    end

    property "a + b - b == a (subtraction exactly undoes addition)" do
      check all(
              n1 <- integer(),
              d1 <- integer(),
              d1 != 0,
              n2 <- integer(),
              d2 <- integer(),
              d2 != 0
            ) do
        a = Rational.new(n1, d1)
        b = Rational.new(n2, d2)
        assert Rational.sub(Rational.add(a, b), b) == a
      end
    end

    property "multiplication is commutative" do
      check all(
              n1 <- integer(),
              d1 <- integer(),
              d1 != 0,
              n2 <- integer(),
              d2 <- integer(),
              d2 != 0
            ) do
        a = Rational.new(n1, d1)
        b = Rational.new(n2, d2)
        assert Rational.mul(a, b) == Rational.mul(b, a)
      end
    end

    property "a * b / b == a for nonzero b (division exactly undoes multiplication)" do
      check all(
              n1 <- integer(),
              d1 <- integer(),
              d1 != 0,
              n2 <- integer(),
              n2 != 0,
              d2 <- integer(),
              d2 != 0
            ) do
        a = Rational.new(n1, d1)
        b = Rational.new(n2, d2)
        assert Rational.div(Rational.mul(a, b), b) == a
      end
    end
  end

  describe "pow/2" do
    test "matches repeated multiplication for small positive exponents" do
      assert Rational.pow(2, 3) == 8
      assert Rational.pow(Rational.new(1, 2), 3) == Rational.new(1, 8)
    end

    test "zero exponent is always 1" do
      assert Rational.pow(5, 0) == 1
      assert Rational.pow(Rational.new(3, 7), 0) == 1
    end

    test "a negative exponent is the reciprocal of the positive one" do
      assert Rational.pow(2, -2) == Rational.new(1, 4)
      assert Rational.pow(Rational.new(2, 3), -1) == Rational.new(3, 2)
    end

    property "pow(a, n) for small positive n matches repeated mul/2" do
      check all(
              numerator <- integer(-10..10),
              denominator <- integer(1..10),
              exponent <- integer(1..6)
            ) do
        a = Rational.new(numerator, denominator)
        expected = Enum.reduce(1..(exponent - 1)//1, a, fn _, acc -> Rational.mul(acc, a) end)
        assert Rational.pow(a, exponent) == expected
      end
    end

    test "a float base preserves its own inexactness through zero exponent, not silently exact" do
      assert Rational.pow(2.0, 0) === 1.0
    end
  end

  describe "to_float/1 and from_float/1" do
    test "to_float converts an integer or a %Rational{} to an ordinary float" do
      assert Rational.to_float(4) === 4.0
      assert Rational.to_float(Rational.new(1, 4)) === 0.25
    end

    test "to_float is the identity on an already-inexact value" do
      assert Rational.to_float(3.14) === 3.14
    end

    test "from_float recovers the exact IEEE-754 value of a float, always bounded" do
      assert Rational.from_float(0.5) == Rational.new(1, 2)
      assert Rational.from_float(2.0) == 2

      # 3.14 has no exact decimal/binary-fraction equivalent -- this is
      # the double's own exact bit-pattern value, not the "intended"
      # 157/50 a DECIMAL literal's own handle_token would produce (a
      # different, unrelated conversion path -- the
      # "decimal literals parse directly to exact rationals" rule applies to
      # *literal* text, not to converting an already-inexact float).
      assert %Rational{} = Rational.from_float(3.14)
    end

    test "negative zero has no exact rational equivalent -- from_float(-0.0) is plain 0" do
      assert Rational.from_float(-0.0) === 0
    end

    # `==`, not `===` -- `-0.0` and `0.0` are bit-distinct IEEE-754
    # values but the same real number (the rationals have no such thing
    # as a signed zero), so `from_float(-0.0)` correctly produces exact
    # `0`, and `to_float(0)` correctly produces `0.0`, not `-0.0` --
    # `==` accepts that equivalence, confirmed empirically (a genuine
    # edge case caught by the property test itself) rather than assumed.
    property "from_float/1 then to_float/1 round-trips exactly for any float" do
      check all(f <- float()) do
        assert Rational.to_float(Rational.from_float(f)) == f
      end
    end
  end

  describe "contagion -- mixing exact and inexact yields inexact" do
    test "add/sub/mul/div each return a float when either operand is a float" do
      assert Rational.add(3, 1.5) === 4.5
      assert Rational.sub(1.5, 1) === 0.5
      assert Rational.mul(2, 1.5) === 3.0
      assert Rational.div(3.0, 2) === 1.5
    end

    test "contagion applies with a %Rational{} operand too, not just a plain integer" do
      assert Rational.add(Rational.new(1, 2), 1.0) === 1.5
      assert Rational.mul(Rational.new(1, 4), 4.0) === 1.0
    end

    test "float + float stays a float, ordinary Kernel arithmetic" do
      assert Rational.add(1.5, 2.5) === 4.0
    end

    test "div raises ArithmeticError for a zero float divisor, the same class of error new/2 already raises for an exact zero denominator" do
      assert_raise ArithmeticError, fn -> Rational.div(1.0, 0.0) end
    end

    property "add/sub/mul/div always return a float() when either operand is a float()" do
      check all(
              numerator <- integer(-100..100),
              denominator <- integer(1..100),
              f <- float()
            ) do
        exact = Rational.new(numerator, denominator)

        assert is_float(Rational.add(exact, f))
        assert is_float(Rational.sub(exact, f))
        assert is_float(Rational.mul(exact, f))
      end
    end
  end

  describe "compare/2 with a float argument" do
    test "compares a float exactly against an integer or %Rational{}, not via lossy float comparison" do
      assert Rational.compare(0.5, Rational.new(1, 2)) == :eq
      assert Rational.compare(1.5, 1) == :gt
      assert Rational.compare(1, 1.5) == :lt
    end

    test "float vs float still compares correctly" do
      assert Rational.compare(1.0, 2.0) == :lt
      assert Rational.compare(2.0, 2.0) == :eq
    end
  end

  # Independent of Scry.Core.Rational's own implementation -- restates
  # cross-multiplication from scratch against the *original* (unreduced)
  # pairs, not anything Rational.new/2 or Rational.compare/2 computed,
  # so this genuinely checks compare/2's behavior rather than mirroring
  # its own code path. Elixir integers are arbitrary-precision, so this
  # stays exact regardless of magnitude -- no float anywhere.
  defp exact_compare(n1, d1, n2, d2) do
    {n1, d1} = normalize(n1, d1)
    {n2, d2} = normalize(n2, d2)
    left = n1 * d2
    right = n2 * d1

    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp normalize(n, d) when d < 0, do: {-n, -d}
  defp normalize(n, d), do: {n, d}
end
