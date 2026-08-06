defmodule ScryCore.WithCycleCheckTest do
  use ExUnit.Case, async: true

  alias ScryCore.{Query, WithCycleCheck}

  test "an empty with_bindings map is trivially fine" do
    assert :ok = WithCycleCheck.check(%{})
  end

  test "bindings that reference only real sources are fine" do
    bindings = %{
      "a" => %Query{source: ["users"], select: []},
      "b" => %Query{source: ["orders"], select: []}
    }

    assert :ok = WithCycleCheck.check(bindings)
  end

  test "a binding referencing another (non-cyclic) binding is fine" do
    bindings = %{
      "base" => %Query{source: ["users"], select: []},
      "derived" => %Query{source: ["base"], select: []}
    }

    assert :ok = WithCycleCheck.check(bindings)
  end

  test "a binding referencing a WITH name only inside a nested SELECT is still checked" do
    bindings = %{
      "base" => %Query{source: ["users"], select: []},
      "derived" => %Query{
        source: ["orders"],
        select: [%Query{source: ["base"], select: []}]
      }
    }

    assert :ok = WithCycleCheck.check(bindings)
  end

  test "a binding that references itself directly is a cycle" do
    bindings = %{"a" => %Query{source: ["a"], select: []}}

    assert {:error, {:with_cycle, ["a", "a"]}} = WithCycleCheck.check(bindings)
  end

  test "a two-binding mutual cycle is caught" do
    bindings = %{
      "a" => %Query{source: ["b"], select: []},
      "b" => %Query{source: ["a"], select: []}
    }

    assert {:error, {:with_cycle, ["a", "b", "a"]}} = WithCycleCheck.check(bindings)
  end

  test "a longer cycle through a third binding is caught, not just two-binding ping-pong" do
    bindings = %{
      "a" => %Query{source: ["b"], select: []},
      "b" => %Query{source: ["c"], select: []},
      "c" => %Query{source: ["a"], select: []}
    }

    assert {:error, {:with_cycle, ["a", "b", "c", "a"]}} = WithCycleCheck.check(bindings)
  end

  test "a cycle reachable only through a nested SELECT is caught" do
    bindings = %{
      "a" => %Query{
        source: ["orders"],
        select: [%Query{source: ["b"], select: []}]
      },
      "b" => %Query{source: ["a"], select: []}
    }

    assert {:error, {:with_cycle, ["a", "b", "a"]}} = WithCycleCheck.check(bindings)
  end
end
