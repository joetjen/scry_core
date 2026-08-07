defmodule Scry.Core.FragmentResolverTest do
  use ExUnit.Case, async: true

  alias Scry.Core.{FragmentResolver, Query}

  test "a query with no spreads resolves unchanged, regardless of what's in the fragment map" do
    query = %Query{source: ["users"], select: [{:field, ["name"]}]}

    assert {:ok, %Query{select: [{:field, ["name"]}]}} =
             FragmentResolver.resolve(query, %{"unused" => [{:field, ["ignored"]}]})
  end

  test "a single spread is replaced by its fragment's own body, in place" do
    query = %Query{source: ["users"], select: [{:field, ["name"]}, {:spread, "ids"}]}
    fragments = %{"ids" => [{:field, ["id"]}, {:field, ["uuid"]}]}

    assert {:ok, %Query{select: select}} = FragmentResolver.resolve(query, fragments)
    assert select == [{:field, ["name"]}, {:field, ["id"]}, {:field, ["uuid"]}]
  end

  test "a fragment spreading another fragment is resolved transitively" do
    query = %Query{source: ["users"], select: [{:spread, "summary"}]}

    fragments = %{
      "base" => [{:field, ["id"]}],
      "summary" => [{:spread, "base"}, {:field, ["name"]}]
    }

    assert {:ok, %Query{select: select}} = FragmentResolver.resolve(query, fragments)
    assert select == [{:field, ["id"]}, {:field, ["name"]}]
  end

  test "a spread inside a nested query's own body is resolved too" do
    nested = %Query{source: ["orders"], select: [{:spread, "fields"}]}
    query = %Query{source: ["users"], select: [{:field, ["name"]}, nested]}
    fragments = %{"fields" => [{:field, ["id"]}, {:field, ["total"]}]}

    assert {:ok, %Query{select: [{:field, ["name"]}, resolved_nested]}} =
             FragmentResolver.resolve(query, fragments)

    assert resolved_nested == %Query{
             source: ["orders"],
             select: [{:field, ["id"]}, {:field, ["total"]}]
           }
  end

  test "an undefined fragment name is a real, reportable error" do
    query = %Query{source: ["users"], select: [{:spread, "missing"}]}

    assert {:error, {:undefined_fragment, "missing"}} =
             FragmentResolver.resolve(query, %{})
  end

  test "a fragment that spreads itself directly is a cycle error" do
    query = %Query{source: ["users"], select: [{:spread, "a"}]}
    fragments = %{"a" => [{:spread, "a"}]}

    assert {:error, {:fragment_cycle, ["a", "a"]}} = FragmentResolver.resolve(query, fragments)
  end

  test "a fragment cycle through a third fragment is caught, not just a two-fragment ping-pong" do
    query = %Query{source: ["users"], select: [{:spread, "a"}]}
    fragments = %{"a" => [{:spread, "b"}], "b" => [{:spread, "c"}], "c" => [{:spread, "a"}]}

    assert {:error, {:fragment_cycle, ["a", "b", "c", "a"]}} =
             FragmentResolver.resolve(query, fragments)
  end

  test "a fragment referenced from two different places is only walked once (memoized)" do
    query = %Query{
      source: ["users"],
      select: [{:spread, "shared"}, {:spread, "shared"}]
    }

    fragments = %{"shared" => [{:field, ["id"]}]}

    assert {:ok, %Query{select: select}} = FragmentResolver.resolve(query, fragments)
    assert select == [{:field, ["id"]}, {:field, ["id"]}]
  end

  test "an undefined fragment referenced only from inside another fragment still errors" do
    query = %Query{source: ["users"], select: [{:spread, "outer"}]}
    fragments = %{"outer" => [{:spread, "missing"}]}

    assert {:error, {:undefined_fragment, "missing"}} =
             FragmentResolver.resolve(query, fragments)
  end
end
