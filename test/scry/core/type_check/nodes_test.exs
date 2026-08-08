defmodule Scry.Core.TypeCheck.NodesTest do
  use ExUnit.Case, async: true

  alias Scry.Core.{CombinedQuery, Query, TypeCheck.Nodes}

  describe "each/2" do
    test "visits a plain query exactly once" do
      query = %Query{source: ["users"], select: []}
      assert :ok = Nodes.each(query, fn %Query{source: ["users"]} -> :ok end)
    end

    test "visits a nested query inside select, depth-first" do
      nested = %Query{source: ["orders"], select: []}
      top = %Query{source: ["users"], select: [nested, {:field, ["id"]}]}

      {:ok, visited} =
        {:ok, Agent.start_link(fn -> [] end) |> elem(1)}

      :ok =
        Nodes.each(top, fn %Query{source: [name]} ->
          Agent.update(visited, &[name | &1])
          :ok
        end)

      assert Agent.get(visited, &Enum.reverse/1) == ["users", "orders"]
    end

    test "visits every with_bindings value" do
      bound = %Query{source: ["orders"], select: []}
      top = %Query{source: ["users"], select: [], with_bindings: %{"o" => bound}}

      {:ok, agent} = Agent.start_link(fn -> [] end)

      :ok =
        Nodes.each(top, fn %Query{source: [name]} ->
          Agent.update(agent, &[name | &1])
          :ok
        end)

      assert Agent.get(agent, &Enum.reverse/1) == ["users", "orders"]
    end

    test "visits both sides of a CombinedQuery" do
      left = %Query{source: ["users"], select: []}
      right = %Query{source: ["customers"], select: []}
      combined = %CombinedQuery{op: :union, left: left, right: right}

      {:ok, agent} = Agent.start_link(fn -> [] end)

      :ok =
        Nodes.each(combined, fn %Query{source: [name]} ->
          Agent.update(agent, &[name | &1])
          :ok
        end)

      assert Agent.get(agent, &Enum.reverse/1) == ["users", "customers"]
    end

    test "halts on the first error, visiting nothing after it" do
      nested = %Query{source: ["orders"], select: []}
      top = %Query{source: ["users"], select: [nested]}

      {:ok, agent} = Agent.start_link(fn -> [] end)

      result =
        Nodes.each(top, fn %Query{source: [name]} = q ->
          Agent.update(agent, &[name | &1])

          if q.source == ["users"] do
            {:error, :boom}
          else
            :ok
          end
        end)

      assert result == {:error, :boom}
      assert Agent.get(agent, &Enum.reverse/1) == ["users"]
    end
  end

  describe "collect/3" do
    test "folds over every node, never halting" do
      nested = %Query{source: ["orders"], select: []}
      bound = %Query{source: ["archive"], select: []}

      top = %Query{
        source: ["users"],
        select: [nested],
        with_bindings: %{"a" => bound}
      }

      names =
        Nodes.collect(top, [], fn %Query{source: [name]}, acc -> [name | acc] end)
        |> Enum.reverse()

      assert names == ["users", "orders", "archive"]
    end

    test "folds over both sides of a CombinedQuery" do
      left = %Query{source: ["users"], select: []}
      right = %Query{source: ["customers"], select: []}
      combined = %CombinedQuery{op: :union, left: left, right: right}

      names =
        Nodes.collect(combined, [], fn %Query{source: [name]}, acc -> [name | acc] end)
        |> Enum.reverse()

      assert names == ["users", "customers"]
    end
  end
end
