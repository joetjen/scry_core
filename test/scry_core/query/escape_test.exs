defmodule ScryCore.Query.EscapeTest do
  use ExUnit.Case, async: true

  alias ScryCore.Query.Escape

  defp predicate(ast), do: ast |> Escape.escape_predicate(:u, __ENV__) |> eval()
  defp expr(ast), do: ast |> Escape.escape_expr(:u, __ENV__) |> eval()
  defp path(ast), do: ast |> Escape.escape_path(:u, __ENV__) |> eval()
  defp eval(quoted), do: quoted |> Code.eval_quoted() |> elem(0)

  describe "escape_predicate/3" do
    test "comparison operators" do
      assert predicate(quote(do: u.age == 30)) == {:cmp, :eq, ["age"], 30}
      assert predicate(quote(do: u.age != 30)) == {:cmp, :not_eq, ["age"], 30}
      assert predicate(quote(do: u.age < 30)) == {:cmp, :lt, ["age"], 30}
      assert predicate(quote(do: u.age > 30)) == {:cmp, :gt, ["age"], 30}
      assert predicate(quote(do: u.age <= 30)) == {:cmp, :le, ["age"], 30}
      assert predicate(quote(do: u.age >= 30)) == {:cmp, :ge, ["age"], 30}
    end

    test "and/or/not" do
      assert predicate(quote(do: u.age > 18 and u.status == "active")) ==
               {:and, {:cmp, :gt, ["age"], 18}, {:cmp, :eq, ["status"], "active"}}

      assert predicate(quote(do: u.age > 18 or u.status == "active")) ==
               {:or, {:cmp, :gt, ["age"], 18}, {:cmp, :eq, ["status"], "active"}}

      assert predicate(quote(do: not (u.age < 18))) == {:not, {:cmp, :lt, ["age"], 18}}
    end

    test "in, against a bracketed literal list" do
      assert predicate(quote(do: u.status in ["active", "pending"])) ==
               {:in, ["status"], ["active", "pending"]}
    end

    test "^pin on a predicate's own right-hand side becomes a named param" do
      assert predicate(quote(do: u.age > ^min_age)) ==
               {:cmp, :gt, ["age"], {:param, "min_age"}}
    end

    test "a recognized call on a predicate's own left-hand side" do
      assert predicate(quote(do: count(u.name) > 1)) ==
               {:cmp, :gt, {:call, "count", [{:field, ["name"]}]}, 1}
    end

    test "a dotted path deeper than one segment" do
      assert predicate(quote(do: u.metadata.color == "red")) ==
               {:cmp, :eq, ["metadata", "color"], "red"}
    end

    test "an arithmetic expression on a predicate's own right-hand side is a clear error" do
      assert_raise ArgumentError, ~r/not a valid predicate right-hand side/, fn ->
        predicate(quote(do: u.age > 1 + 1))
      end
    end

    test "a bare (unpinned) variable on the right-hand side is a clear error" do
      assert_raise ArgumentError, ~r/did you mean `\^min_age`/, fn ->
        predicate(quote(do: u.age > min_age))
      end
    end

    test "^ on anything but a bare local variable is a clear error" do
      assert_raise ArgumentError, ~r/a pin must be a bare local variable/, fn ->
        expr(quote(do: ^(1 + 1)))
      end
    end

    test "a variable not matching the bound variable is a clear error" do
      assert_raise ArgumentError, ~r/doesn't resolve to the bound variable `u`/, fn ->
        predicate(quote(do: other.name == "x"))
      end
    end

    test "something that isn't a predicate at all is a clear error" do
      assert_raise ArgumentError, ~r/is not a valid predicate/, fn ->
        predicate(quote(do: u.age))
      end
    end
  end

  describe "escape_expr/3" do
    test "a dotted field path" do
      assert expr(quote(do: u.name)) == {:field, ["name"]}
      assert expr(quote(do: u.metadata.color)) == {:field, ["metadata", "color"]}
    end

    test "^pin becomes a named param" do
      assert expr(quote(do: ^some_id)) == {:param, "some_id"}
    end

    test "arithmetic, including ** for pow" do
      assert expr(quote(do: u.price * u.quantity)) ==
               {:arith, :mul, {:field, ["price"]}, {:field, ["quantity"]}}

      assert expr(quote(do: u.price + 1)) == {:arith, :add, {:field, ["price"]}, 1}
      assert expr(quote(do: u.price - 1)) == {:arith, :sub, {:field, ["price"]}, 1}
      assert expr(quote(do: u.price / 2)) == {:arith, :div, {:field, ["price"]}, 2}
      assert expr(quote(do: u.price ** 2)) == {:arith, :pow, {:field, ["price"]}, 2}
    end

    test "a recognized call, nested arguments included" do
      assert expr(quote(do: sum(u.total))) == {:call, "sum", [{:field, ["total"]}]}

      assert expr(quote(do: sum(u.price * u.quantity))) ==
               {:call, "sum", [{:arith, :mul, {:field, ["price"]}, {:field, ["quantity"]}}]}
    end

    test "an unrecognized function name is a clear error" do
      assert_raise ArgumentError, ~r/not a recognized Scry function/, fn ->
        expr(quote(do: length(u.name)))
      end
    end

    test "literals pass through unchanged" do
      assert expr(quote(do: 42)) == 42
      assert expr(quote(do: "hi")) == "hi"
      assert expr(quote(do: true)) == true
      assert expr(quote(do: nil)) == nil
    end

    test "cond becomes {:when, clauses, else_expr}" do
      ast =
        quote do
          cond do
            u.age < 18 -> "minor"
            u.age < 65 -> "adult"
            true -> "senior"
          end
        end

      assert expr(ast) ==
               {:when,
                [
                  {{:cmp, :lt, ["age"], 18}, "minor"},
                  {{:cmp, :lt, ["age"], 65}, "adult"}
                ], "senior"}
    end

    test "a cond whose final clause isn't `true ->` is a clear compile error" do
      ast =
        quote do
          cond do
            u.age < 18 -> "minor"
            u.age < 65 -> "adult"
          end
        end

      assert_raise ArgumentError, ~r/must end with a `true ->` clause/, fn -> expr(ast) end
    end
  end

  describe "escape_path/3" do
    test "resolves a dotted path to a bare list, not a wrapped {:field, ...}" do
      assert path(quote(do: u.region)) == ["region"]
      assert path(quote(do: u.a.b)) == ["a", "b"]
    end

    test "a bare bound variable with no field is a clear error" do
      assert_raise ArgumentError, ~r/isn't a valid field path/, fn -> path(quote(do: u)) end
    end
  end
end
