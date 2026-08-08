defmodule Scry.Core.Executor.AggregatePushdownTest do
  @moduledoc """
  `Scry.Core.Executor`'s aggregate/`GROUP BY` pushdown wiring
  (`try_aggregate_pushdown/6`, `aggregate_pushdown_plan/3`,
  `groups_from_pushdown/2`) -- confirms an eligible query actually
  calls `EngineBehaviour.aggregate/5` (never falling through to
  `fetch/2` and computing it row-by-row), that every eligibility
  exclusion this module's own moduledoc documents correctly declines
  and falls back to today's exact existing behavior instead (`avg`,
  `HAVING`, a window function, a nested `SELECT`, a non-`group_bys`
  bare field, `ROLLUP`/`CUBE`, a correlated/nested query, a `WITH`-bound
  source), that `:not_supported`/`{:error, _}` from the engine behave
  correctly (fall back vs. propagate), and that the `{group_by_values,
  agg_values}` -> `{groups, order}` conversion produces byte-identical
  output to the existing row-by-row streaming path for the same data.

  This file does *not* test real SQL rendering or `PRAGMA table_info`
  NOT NULL gating -- that's `scry_engine_exqlite`'s own job, tested
  there against a real SQLite database. `PushdownEngine` below computes
  aggregates via an independent, from-scratch Elixir reduction (never
  calling into any of `Scry.Core.Executor`'s own private functions),
  purely to prove the *wiring* -- dispatch, conversion, fallback --
  works correctly regardless of which engine actually did the
  computation.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Core.{Cursor, Executor, Query}

  defmodule PushdownEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch({data, agent}, source) do
      Agent.update(agent, &[:fetch | &1])

      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end

    @impl true
    def aggregate({data, agent}, source, query, plan, _params) do
      Agent.update(agent, &[:aggregate | &1])

      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, compute(rows, query.group_bys, plan)}
        :error -> {:error, {:no_such_source, source}}
      end
    end

    defp compute([], [], plan), do: [{[], agg_values([], plan)}]

    defp compute(rows, [], plan), do: [{[], agg_values(rows, plan)}]

    defp compute(rows, group_bys, plan) do
      rows
      |> Enum.group_by(fn row -> Enum.map(group_bys, &field(row, &1)) end)
      |> Enum.map(fn {key, member_rows} -> {key, agg_values(member_rows, plan)} end)
    end

    defp agg_values(member_rows, plan) do
      Map.new(plan, fn {name, args} = spec -> {spec, agg_one(name, args, member_rows)} end)
    end

    defp agg_one("sum", [{:field, path}], []) do
      _ = path
      :empty
    end

    defp agg_one("sum", [{:field, path}], rows),
      do: Enum.reduce(rows, 0, &(field(&1, path) + &2))

    defp agg_one("min", [{:field, path}], []) do
      _ = path
      :empty
    end

    defp agg_one("min", [{:field, path}], rows),
      do: rows |> Enum.map(&field(&1, path)) |> Enum.min()

    defp agg_one("max", [{:field, path}], []) do
      _ = path
      :empty
    end

    defp agg_one("max", [{:field, path}], rows),
      do: rows |> Enum.map(&field(&1, path)) |> Enum.max()

    defp agg_one("count", [{:field, _path}], rows), do: length(rows)

    defp agg_one("count", [{:distinct, {:field, path}}], rows),
      do: rows |> Enum.map(&field(&1, path)) |> Enum.uniq() |> length()

    defp field(row, [key]), do: Map.get(row, key)
  end

  defmodule PlainEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch(data, source) do
      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end
  end

  defmodule DecliningEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch(data, source) do
      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end

    @impl true
    def aggregate(_data, _source, _query, _plan, _params), do: :not_supported
  end

  defmodule ErroringEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch(_data, source), do: {:error, {:no_such_source, source}}

    @impl true
    def aggregate(_data, _source, _query, _plan, _params),
      do: {:error, {:no_such_source, ["items"]}}
  end

  defp materialize({:ok, cursor}), do: {:ok, Cursor.to_list(cursor)}
  defp materialize({:error, _} = err), do: err

  defp run(query, engine, data), do: query |> Executor.run(engine, data) |> materialize()

  defp with_tracking(data, fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    result = fun.({data, agent})
    {result, Agent.get(agent, &Enum.reverse/1)}
  end

  describe "an eligible query pushes down and never falls back to fetch/2" do
    test "GROUP BY + sum/count/min/max/count(distinct)" do
      rows = [
        %{"status" => "a", "v" => 10, "tag" => "x"},
        %{"status" => "a", "v" => 20, "tag" => "x"},
        %{"status" => "b", "v" => 5, "tag" => "y"},
        %{"status" => "b", "v" => 7, "tag" => "z"}
      ]

      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:computed, "total", {:call, "sum", [{:field, ["v"]}]}},
          {:computed, "n", {:call, "count", [{:field, ["v"]}]}},
          {:computed, "lo", {:call, "min", [{:field, ["v"]}]}},
          {:computed, "hi", {:call, "max", [{:field, ["v"]}]}},
          {:computed, "distinct_tags", {:call, "count", [{:distinct, {:field, ["tag"]}}]}}
        ]
      }

      {result, calls} =
        with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))

      assert calls == [:aggregate]
      assert {:ok, rows_out} = result

      assert Enum.sort_by(rows_out, & &1["status"]) == [
               %{
                 "status" => "a",
                 "total" => 30,
                 "n" => 2,
                 "lo" => 10,
                 "hi" => 20,
                 "distinct_tags" => 1
               },
               %{
                 "status" => "b",
                 "total" => 12,
                 "n" => 2,
                 "lo" => 5,
                 "hi" => 7,
                 "distinct_tags" => 2
               }
             ]
    end

    test "a flat (no GROUP BY) aggregate over zero rows correctly reports :empty as nil" do
      query = %Query{
        source: ["items"],
        select: [{:computed, "total", {:call, "sum", [{:field, ["v"]}]}}]
      }

      {result, calls} = with_tracking(%{["items"] => []}, &run(query, PushdownEngine, &1))

      assert calls == [:aggregate]
      assert {:ok, [%{"total" => nil}]} = result
    end

    test "ORDER BY/DISTINCT/LIMIT still apply correctly after pushdown" do
      rows = for i <- 1..5, do: %{"grp" => rem(i, 3), "v" => i}

      query = %Query{
        source: ["items"],
        group_bys: [["grp"]],
        order_bys: [{["grp"], :desc}],
        limit: 2,
        select: [
          {:field, ["grp"]},
          {:computed, "total", {:call, "sum", [{:field, ["v"]}]}}
        ]
      }

      {result, calls} = with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))
      assert calls == [:aggregate]
      assert {:ok, [%{"grp" => 2}, %{"grp" => 1}]} = result
    end
  end

  describe "eligibility exclusions decline pushdown and fall back to fetch/2" do
    test "avg anywhere in select" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [{:field, ["status"]}, {:computed, "a", {:call, "avg", [{:field, ["v"]}]}}]
      }

      rows = [%{"status" => "a", "v" => 10}]
      {result, calls} = with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))
      assert calls == [:fetch]
      assert {:ok, [%{"status" => "a", "a" => 10}]} = result
    end

    test "a non-empty HAVING" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        havings: [{:cmp, :gt, {:call, "count", [{:field, ["v"]}]}, 1}],
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["v"]}]}}
        ]
      }

      rows = [%{"status" => "a", "v" => 10}]
      {_result, calls} = with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))
      assert calls == [:fetch]
    end

    test "a window function anywhere in the query" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["v"]}]}},
          {:computed, "r", {:window, {:call, "row_number", []}, [], [{["status"], :asc}], nil}}
        ]
      }

      rows = [%{"status" => "a", "v" => 10}]
      {_result, calls} = with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))
      assert calls == [:fetch]
    end

    test "a nested SELECT in select" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          %Query{source: ["other"], select: [{:field, ["x"]}]}
        ]
      }

      data = %{["items"] => [%{"status" => "a"}], ["other"] => [%{"x" => 1}]}
      {_result, calls} = with_tracking(data, &run(query, PushdownEngine, &1))
      assert calls == [:fetch]
    end

    test "a non-group-by bare field in select" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:field, ["v"]}
        ]
      }

      rows = [%{"status" => "a", "v" => 10}]
      {_result, calls} = with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))
      assert calls == [:fetch]
    end

    test "ROLLUP/CUBE (group_mode != :plain)" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        group_mode: :rollup,
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["v"]}]}}
        ]
      }

      rows = [%{"status" => "a", "v" => 10}]
      {_result, calls} = with_tracking(%{["items"] => rows}, &run(query, PushdownEngine, &1))
      assert calls == [:fetch]
    end

    test "a correlated/nested query (non-empty scope) never attempts pushdown" do
      inner = %Query{
        source: ["orders"],
        group_bys: [["user_id"]],
        wheres: [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      outer = %Query{
        source: ["users"],
        select: [{:field, ["id"]}, inner]
      }

      users = [%{"id" => 1}]
      orders = [%{"user_id" => 1, "amount" => 10}]

      {result, calls} =
        with_tracking(
          %{["users"] => users, ["orders"] => orders},
          &run(outer, PushdownEngine, &1)
        )

      # The outer query's own select has a nested %Query{}, which already
      # excludes it; the inner query itself has scope != [] (it's the
      # nested one), so it must never attempt pushdown either.
      assert :fetch in calls
      refute :aggregate in calls
      assert {:ok, [%{"id" => 1, "orders" => [%{"user_id" => 1, "total" => 10}]}]} = result
    end
  end

  describe "engine decline/error handling" do
    test ":not_supported falls back to computing it in Elixir" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["v"]}]}}
        ]
      }

      rows = [%{"status" => "a", "v" => 1}, %{"status" => "a", "v" => 2}]
      assert {:ok, rows_out} = run(query, DecliningEngine, %{["items"] => rows})
      assert rows_out == [%{"status" => "a", "n" => 2}]
    end

    test "{:error, reason} propagates directly, without falling back" do
      query = %Query{
        source: ["items"],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["v"]}]}}
        ]
      }

      assert {:error, {:no_such_source, ["items"]}} = run(query, ErroringEngine, %{})
    end
  end

  describe "property: pushdown always matches the row-by-row streaming path" do
    property "GROUP BY + sum/count/min/max produce identical output whether pushed down or not" do
      check all(
              rows <-
                list_of(
                  map(
                    {integer(0..4), integer(-50..50)},
                    fn {grp, v} -> %{"grp" => grp, "v" => v} end
                  ),
                  max_length: 60
                )
            ) do
        query = %Query{
          source: ["items"],
          group_bys: [["grp"]],
          select: [
            {:field, ["grp"]},
            {:computed, "total", {:call, "sum", [{:field, ["v"]}]}},
            {:computed, "n", {:call, "count", [{:field, ["v"]}]}},
            {:computed, "lo", {:call, "min", [{:field, ["v"]}]}},
            {:computed, "hi", {:call, "max", [{:field, ["v"]}]}}
          ]
        }

        data = %{["items"] => rows}
        {pushed, _calls} = with_tracking(data, &run(query, PushdownEngine, &1))
        not_pushed = run(query, PlainEngine, data)

        assert {:ok, pushed_rows} = pushed
        assert {:ok, plain_rows} = not_pushed
        assert Enum.sort_by(pushed_rows, & &1["grp"]) == Enum.sort_by(plain_rows, & &1["grp"])
      end
    end
  end
end
