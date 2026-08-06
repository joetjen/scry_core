defmodule ScryCore.RationalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ScryCore.Rational

  describe "new/2" do
    test "a whole-number result collapses to a plain integer, not the struct" do
      assert Rational.new(6, 3) === 2
      assert Rational.new(6, 2) === 3
      assert Rational.new(0, 5) === 0
    end

    test "matches lang_spec.md's own worked example: 3.14 == 157/50" do
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
  end

  # Independent of ScryCore.Rational's own implementation -- restates
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
