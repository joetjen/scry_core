defmodule Scry.Core.Query.EscapeTest do
  use ExUnit.Case, async: true

  alias Scry.Core.Query.Escape

  defp predicate(ast, vars \\ %{u: :self}),
    do: ast |> Escape.escape_predicate(vars, __ENV__) |> eval()

  defp expr(ast, vars \\ %{u: :self}), do: ast |> Escape.escape_expr(vars, __ENV__) |> eval()
  defp path(ast, vars \\ %{u: :self}), do: ast |> Escape.escape_path(vars, __ENV__) |> eval()
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

    test "a variable not matching any bound variable in scope is a clear error, listing what is" do
      assert_raise ArgumentError, ~r/expected one of: `u`/, fn ->
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

    test "rate/1 -- a plain number of seconds, no 5s-shaped literal" do
      # No `5s`-style duration literal exists in Elixir -- a builder
      # caller passes a plain number of seconds directly, the same way
      # percentile(x, 0.5)'s own `p` argument already does.
      assert expr(quote(do: rate(5))) == {:call, "rate", [5]}
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

  describe "multi-entry vars (nested from / correlation)" do
    @vars %{o: :self, u: "users"}

    test "the :self entry resolves to a bare, unqualified path" do
      assert expr(quote(do: o.total), @vars) == {:field, ["total"]}
      assert path(quote(do: o.total), @vars) == ["total"]
    end

    test "an ancestor entry resolves to a path seeded with its own literal qualifier" do
      assert expr(quote(do: u.id), @vars) == {:field, ["users", "id"]}
      assert path(quote(do: u.id), @vars) == ["users", "id"]
    end

    test "a predicate correlating an ancestor field to the current one" do
      assert predicate(quote(do: o.user_id == u.id), @vars) ==
               {:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}
    end

    test "an unbound variable error lists every name actually in scope" do
      error =
        assert_raise ArgumentError, fn ->
          expr(quote(do: other.name), @vars)
        end

      assert error.message =~ "`o`"
      assert error.message =~ "`u`"
    end
  end

  describe "over/2 (window functions)" do
    test "row_number() OVER PARTITION BY ... ORDER BY ..., a worked example" do
      ast =
        quote do
          over(row_number(), partition_by: [u.department], order_by: [desc: u.salary])
        end

      assert expr(ast) ==
               {:window, {:call, "row_number", []}, [["department"]],
                [{{:field, ["salary"]}, :desc}], nil}
    end

    test "order_by:'s own key is a full expr() now, not just a bare field -- an arithmetic key" do
      ast =
        quote do
          over(row_number(), order_by: [desc: u.price * u.quantity])
        end

      assert expr(ast) ==
               {:window, {:call, "row_number", []}, [],
                [{{:arith, :mul, {:field, ["price"]}, {:field, ["quantity"]}}, :desc}], nil}
    end

    test "an aggregate reused as a window function, with no partition/order at all" do
      assert expr(quote(do: over(sum(u.total), []))) ==
               {:window, {:call, "sum", [{:field, ["total"]}]}, [], [], nil}
    end

    test "rows_between with named frame-bound atoms" do
      ast = quote(do: over(sum(u.total), rows_between: {:unbounded_preceding, :current_row}))

      assert expr(ast) ==
               {:window, {:call, "sum", [{:field, ["total"]}]}, [], [],
                {:unbounded_preceding, :current_row}}
    end

    test "rows_between with {:preceding, n}/{:following, n} bounds" do
      ast = quote(do: over(sum(u.total), rows_between: {{:preceding, 3}, {:following, 1}}))

      assert expr(ast) ==
               {:window, {:call, "sum", [{:field, ["total"]}]}, [], [],
                {{:preceding, 3}, {:following, 1}}}
    end

    test "an unrecognized frame bound is a clear error" do
      assert_raise ArgumentError, ~r/is not a valid frame bound/, fn ->
        expr(quote(do: over(sum(u.total), rows_between: {:bogus, :current_row})))
      end
    end

    test "a non-integer or non-positive n in {:preceding, n} is a clear error" do
      assert_raise ArgumentError, ~r/is not a valid frame bound/, fn ->
        expr(quote(do: over(sum(u.total), rows_between: {{:preceding, 0}, :current_row})))
      end
    end

    test "over/2's own first argument must be a recognized call" do
      assert_raise ArgumentError, ~r/must be a recognized call/, fn ->
        expr(quote(do: over(u.total, [])))
      end
    end
  end
end
