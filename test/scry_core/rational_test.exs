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
