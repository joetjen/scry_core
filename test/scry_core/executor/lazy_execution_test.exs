defmodule ScryCore.Executor.LazyExecutionTest do
  @moduledoc """
  The genuinely new properties `ScryCore.Executor.run/3,4`'s own Cursor-
  returning contract adds, beyond what `executor_test.exs`'s own (much
  larger, unchanged-in-intent) correctness suite already covers: the
  public return shape really is a `Cursor`, a `LIMIT`-bound plain query
  really does stop pulling from the source early (a real step-counted
  proof, not inferred), a `Stream.resource/3`-backed source really gets
  cleaned up on that early stop (not just in isolation against `Cursor`
  directly, as `cursor_test.exs` already covers, but through the real
  `Executor.run/4` path end to end), and a lazily-discovered failure
  (`ScryCore.Executor.QueryError`) only ever surfaces once a caller
  actually pulls far enough to reach it -- never eagerly from `run/4`
  itself.
  """

  use ExUnit.Case, async: true

  alias ScryCore.{Cursor, Executor, Query}
  alias ScryCore.Executor.QueryError

  defmodule CountingEngine do
    @moduledoc false
    @behaviour ScryCore.EngineBehaviour

    @impl true
    def fetch({data, counter}, source) do
      case Map.fetch(data, source) do
        {:ok, rows} ->
          {:ok,
           Stream.map(rows, fn row ->
             :counters.add(counter, 1, 1)
             row
           end)}

        :error ->
          {:error, {:no_such_source, source}}
      end
    end
  end

  defmodule ResourceEngine do
    @moduledoc false
    @behaviour ScryCore.EngineBehaviour

    @impl true
    def fetch({data, agent}, [name]) do
      rows = Map.fetch!(data, [name])

      stream =
        Stream.resource(
          fn -> rows end,
          fn
            [] -> {:halt, []}
            [row | rest] -> {[row], rest}
          end,
          fn _ -> Agent.update(agent, fn _ -> true end) end
        )

      {:ok, stream}
    end
  end

  @items for i <- 1..1000, do: %{"id" => i, "value" => i * 10}

  test "run/4 returns a Cursor, not a materialized list" do
    query = %Query{source: ["items"], select: [{:field, ["id"]}]}

    assert {:ok, %Cursor{}} =
             Executor.run(query, CountingEngine, {%{["items"] => @items}, :counters.new(1, [])})
  end

  test "a LIMIT-bound plain query genuinely stops pulling from the source early" do
    counter = :counters.new(1, [])
    conn = {%{["items"] => @items}, counter}

    query = %Query{
      source: ["items"],
      wheres: [{:cmp, :gt, ["id"], 500}],
      limit: 3,
      select: [{:field, ["id"]}]
    }

    assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)
    assert Cursor.to_list(cursor) == [%{"id" => 501}, %{"id" => 502}, %{"id" => 503}]

    # 1000 items in the source; only the first 503 needed pulling to
    # satisfy WHERE id > 500 LIMIT 3 -- proves the source was never
    # fully materialized, not just that the right rows came back.
    assert :counters.get(counter, 1) == 503
  end

  test "OFFSET + LIMIT together only pull as far as offset + limit requires" do
    counter = :counters.new(1, [])
    conn = {%{["items"] => @items}, counter}

    query = %Query{source: ["items"], limit: 3, offset: 5, select: [{:field, ["id"]}]}

    assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)
    assert Cursor.to_list(cursor) == [%{"id" => 6}, %{"id" => 7}, %{"id" => 8}]
    assert :counters.get(counter, 1) == 8
  end

  test "a query with no LIMIT at all still streams (bounded working memory), pulling every row exactly once" do
    counter = :counters.new(1, [])
    conn = {%{["items"] => @items}, counter}

    query = %Query{
      source: ["items"],
      wheres: [{:cmp, :gt, ["id"], 995}],
      select: [{:field, ["id"]}]
    }

    assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)

    assert Cursor.to_list(cursor) == [
             %{"id" => 996},
             %{"id" => 997},
             %{"id" => 998},
             %{"id" => 999},
             %{"id" => 1000}
           ]

    assert :counters.get(counter, 1) == 1000
  end

  test "a Stream.resource/3-backed source's own after_fun runs on early LIMIT stop, through the real Executor.run/4 path" do
    {:ok, agent} = Agent.start_link(fn -> false end)
    conn = {%{["items"] => @items}, agent}

    query = %Query{source: ["items"], limit: 2, select: [{:field, ["id"]}]}

    assert {:ok, cursor} = Executor.run(query, ResourceEngine, conn)
    assert Cursor.to_list(cursor) == [%{"id" => 1}, %{"id" => 2}]
    assert Agent.get(agent, & &1)
  end

  test "a lazily-discovered failure (an unsupported body item) does not surface from run/4 itself" do
    query = %Query{source: ["items"], select: [{:variant, %{fake: true}}]}
    conn = {%{["items"] => @items}, :counters.new(1, [])}

    assert {:ok, %Cursor{}} = Executor.run(query, CountingEngine, conn)
  end

  test "...but raises QueryError once a caller actually pulls far enough to reach it" do
    query = %Query{source: ["items"], select: [{:variant, %{fake: true}}]}
    conn = {%{["items"] => @items}, :counters.new(1, [])}

    assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)

    assert_raise QueryError, ~r/unsupported_body_item/, fn ->
      Cursor.to_list(cursor)
    end
  end

  test "QueryError's own reason matches project_item/8's real {:unsupported_body_item, item} shape" do
    item = {:variant, %{fake: true}}
    query = %Query{source: ["items"], select: [item]}
    conn = {%{["items"] => @items}, :counters.new(1, [])}

    {:ok, cursor} = Executor.run(query, CountingEngine, conn)

    error =
      assert_raise QueryError, fn ->
        Cursor.to_list(cursor)
      end

    assert error.reason == {:unsupported_body_item, item}
  end

  describe "streaming aggregation's own detection boundary (streaming_aggregate_plan/1)" do
    @orders [
      %{"customer_id" => 1, "total" => 50},
      %{"customer_id" => 1, "total" => 75},
      %{"customer_id" => 3, "total" => 20}
    ]

    test "a direct streaming-capable aggregate call streams -- never pulls a member-row list back out" do
      counter = :counters.new(1, [])
      conn = {%{["orders"] => @orders}, counter}

      query = %Query{
        source: ["orders"],
        group_bys: [["customer_id"]],
        select: [
          {:field, ["customer_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)

      assert Enum.sort(Cursor.to_list(cursor)) ==
               Enum.sort([
                 %{"customer_id" => 1, "total" => 125},
                 %{"customer_id" => 3, "total" => 20}
               ])

      assert :counters.get(counter, 1) == 3
    end

    test "an aggregate nested inside arithmetic falls back to the eager path -- still produces the correct result" do
      counter = :counters.new(1, [])
      conn = {%{["orders"] => @orders}, counter}

      query = %Query{
        source: ["orders"],
        group_bys: [["customer_id"]],
        select: [
          {:field, ["customer_id"]},
          {:computed, "doubled", {:arith, :mul, {:call, "avg", [{:field, ["total"]}]}, 2}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)

      assert Enum.sort(Cursor.to_list(cursor)) ==
               Enum.sort([
                 %{"customer_id" => 1, "doubled" => ScryCore.Rational.new(125, 1)},
                 %{"customer_id" => 3, "doubled" => 40}
               ])
    end

    test "percentile falls back to the eager path -- still produces the correct result" do
      conn = {%{["orders"] => @orders}, :counters.new(1, [])}

      query = %Query{
        source: ["orders"],
        group_bys: [["customer_id"]],
        select: [
          {:field, ["customer_id"]},
          {:computed, "p", {:call, "percentile", [{:field, ["total"]}, 0.5]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)

      assert Enum.sort(Cursor.to_list(cursor)) ==
               Enum.sort([%{"customer_id" => 1, "p" => 50}, %{"customer_id" => 3, "p" => 20}])
    end

    test "a window function layered on a streaming-capable GROUP BY still streams the source scan" do
      # `run_grouped_with_windows/7` reuses `streaming_aggregate_plan/1`
      # against the window-stripped select before ever falling back to
      # the eager path -- this is the source-scan step-counted proof
      # that a window function doesn't silently force that fallback.
      counter = :counters.new(1, [])
      conn = {%{["orders"] => @orders}, counter}

      query = %Query{
        source: ["orders"],
        group_bys: [["customer_id"]],
        select: [
          {:field, ["customer_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["total"]}]}},
          {:computed, "rank", {:window, {:call, "row_number", []}, [], [{["total"], :desc}], nil}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, CountingEngine, conn)

      assert Enum.sort(Cursor.to_list(cursor)) ==
               Enum.sort([
                 %{"customer_id" => 1, "total" => 125, "rank" => 1},
                 %{"customer_id" => 3, "total" => 20, "rank" => 2}
               ])

      # 3 source rows total -- every one pulled exactly once, none of
      # them re-fetched by the (small, group-count-sized) window pass
      # that runs afterward.
      assert :counters.get(counter, 1) == 3
    end
  end
end
