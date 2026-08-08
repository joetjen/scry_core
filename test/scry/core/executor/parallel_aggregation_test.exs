defmodule Scry.Core.Executor.ParallelAggregationTest do
  @moduledoc """
  `Scry.Core.Executor`'s parallel, chunked streaming-aggregation path
  (`accumulate_groups_parallel/5`, `merge_group_state/2`) -- confirms
  it produces byte-identical results to the single-process semantics
  it replaced (first-appearance order, representative-row selection,
  every streaming-capable aggregate's own running total) across
  datasets deliberately spanning many chunks, that a hard error deep
  inside a later chunk still surfaces as an ordinary, catchable
  exception in the calling process rather than crashing it (the whole
  reason this path runs under `Scry.Core.TaskSupervisor` via
  `Task.Supervisor.async_stream_nolink/4`, not a linked task), and that
  a real `Stream.resource/3`-backed source still gets cleaned up
  correctly through this new consumption pattern.

  Every test here forces a tiny `parallel_chunk_size` (`Application.
  put_env(:scry_core, :parallel_chunk_size, n)`, restored via
  `on_exit`) so a dataset of a few dozen rows genuinely spans several
  chunks -- the real correctness risk is the *merge* logic across
  chunk boundaries, not the (nearly unchanged) single-chunk case, and
  a real-scale dataset would make that risk invisible without forcing
  small chunks here. `async: false`: `parallel_chunk_size`/
  `parallel_max_concurrency` are process-global `Application` env, and
  no other test file touches either key, but mutating global state is
  never safe to run concurrently with itself.

  Expect `[error] Task ... terminating` log lines from several tests
  below -- `Task.Supervisor`'s own standard crash reporting for a
  worker that raised on purpose (this suite's own hard-error cases),
  not a sign anything is actually broken; the tests themselves assert
  the calling process survives and receives an ordinary, rescuable
  exception.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Scry.Core.{Cursor, Executor, Query, Rational}

  defmodule TestEngine do
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

  defmodule ResourceEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch({rows, agent}, _source) do
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

  defp materialize({:ok, cursor}), do: {:ok, Cursor.to_list(cursor)}
  defp materialize({:error, _} = err), do: err

  defp run(query, data), do: query |> Executor.run(TestEngine, data) |> materialize()

  defp with_chunk_size(size, fun) do
    Application.put_env(:scry_core, :parallel_chunk_size, size)

    try do
      fun.()
    after
      Application.delete_env(:scry_core, :parallel_chunk_size)
    end
  end

  describe "correctness across chunk boundaries" do
    test "a flat sum/count/avg/min/max spanning many chunks matches hand-computed totals" do
      with_chunk_size(3, fn ->
        rows = for i <- 1..37, do: %{"v" => i}

        query = %Query{
          source: ["items"],
          select: [
            {:computed, "total", {:call, "sum", [{:field, ["v"]}]}},
            {:computed, "n", {:call, "count", [{:field, ["v"]}]}},
            {:computed, "a", {:call, "avg", [{:field, ["v"]}]}},
            {:computed, "lo", {:call, "min", [{:field, ["v"]}]}},
            {:computed, "hi", {:call, "max", [{:field, ["v"]}]}}
          ]
        }

        assert {:ok, [row]} = run(query, %{["items"] => rows})
        assert row["total"] == Enum.sum(1..37)
        assert row["n"] == 37
        assert row["a"] == Rational.new(Enum.sum(1..37), 37)
        assert row["lo"] == 1
        assert row["hi"] == 37
      end)
    end

    test "GROUP BY spanning many chunks matches hand-computed per-group totals" do
      with_chunk_size(4, fn ->
        # 60 rows, 5 groups, interleaved so every group has members
        # scattered across many different chunks, not conveniently
        # confined to just one.
        rows = for i <- 1..60, do: %{"group" => rem(i, 5), "v" => i}

        query = %Query{
          source: ["items"],
          group_bys: [["group"]],
          select: [
            {:field, ["group"]},
            {:computed, "total", {:call, "sum", [{:field, ["v"]}]}},
            {:computed, "n", {:call, "count", [{:field, ["v"]}]}}
          ]
        }

        assert {:ok, rows_out} = run(query, %{["items"] => rows})

        expected =
          rows
          |> Enum.group_by(& &1["group"])
          |> Enum.map(fn {group, members} ->
            %{
              "group" => group,
              "total" => Enum.sum(Enum.map(members, & &1["v"])),
              "n" => length(members)
            }
          end)

        assert Enum.sort_by(rows_out, & &1["group"]) == Enum.sort_by(expected, & &1["group"])
      end)
    end

    test "count(distinct ...) unions correctly even when the same value appears in different chunks" do
      with_chunk_size(2, fn ->
        # "a" appears in the 1st, 3rd, and 5th chunk -- must still count
        # once, not three times, proving the merge is a real set union,
        # not just concatenation.
        rows = [
          %{"tag" => "a"},
          %{"tag" => "b"},
          %{"tag" => "c"},
          %{"tag" => "d"},
          %{"tag" => "a"},
          %{"tag" => "e"},
          %{"tag" => "a"},
          %{"tag" => "f"}
        ]

        query = %Query{
          source: ["items"],
          select: [{:computed, "n", {:call, "count", [{:distinct, {:field, ["tag"]}}]}}]
        }

        assert {:ok, [%{"n" => 6}]} = run(query, %{["items"] => rows})
      end)
    end

    test "the representative row is the true first-appearance row, even across chunk boundaries" do
      with_chunk_size(2, fn ->
        rows = [
          %{"group" => "x", "seen_at" => 1},
          %{"group" => "y", "seen_at" => 2},
          %{"group" => "x", "seen_at" => 3},
          %{"group" => "y", "seen_at" => 4},
          %{"group" => "x", "seen_at" => 5}
        ]

        query = %Query{
          source: ["items"],
          group_bys: [["group"]],
          select: [{:field, ["group"]}, {:field, ["seen_at"]}]
        }

        assert {:ok, rows_out} = run(query, %{["items"] => rows})

        # The representative for each group must be that group's own
        # *first* row in true fetch order (x -> seen_at 1, y -> seen_at
        # 2) -- not whichever chunk happened to finish processing
        # first, and not the group's last-seen row either.
        assert Enum.sort_by(rows_out, & &1["group"]) ==
                 Enum.sort_by(
                   [%{"group" => "x", "seen_at" => 1}, %{"group" => "y", "seen_at" => 2}],
                   & &1["group"]
                 )
      end)
    end

    test "first-appearance group *order* is preserved across chunk boundaries too" do
      with_chunk_size(2, fn ->
        # Groups first appear in the order d, b, c, a -- the parallel
        # path must reproduce that exact order, not group-key sort
        # order or chunk-completion order.
        rows = [
          %{"group" => "d", "v" => 1},
          %{"group" => "b", "v" => 2},
          %{"group" => "c", "v" => 3},
          %{"group" => "d", "v" => 4},
          %{"group" => "a", "v" => 5},
          %{"group" => "b", "v" => 6}
        ]

        query = %Query{
          source: ["items"],
          group_bys: [["group"]],
          select: [{:field, ["group"]}]
        }

        assert {:ok, rows_out} = run(query, %{["items"] => rows})
        assert Enum.map(rows_out, & &1["group"]) == ["d", "b", "c", "a"]
      end)
    end

    test "HAVING, ORDER BY, and LIMIT still compose correctly on top of the parallel path" do
      with_chunk_size(3, fn ->
        rows = for i <- 1..30, do: %{"group" => rem(i, 6), "v" => i}

        query = %Query{
          source: ["items"],
          group_bys: [["group"]],
          havings: [{:cmp, :gt, {:call, "sum", [{:field, ["v"]}]}, 50}],
          order_bys: [{["group"], :asc}],
          limit: 2,
          select: [
            {:field, ["group"]},
            {:computed, "total", {:call, "sum", [{:field, ["v"]}]}}
          ]
        }

        assert {:ok, rows_out} = run(query, %{["items"] => rows})

        expected =
          rows
          |> Enum.group_by(& &1["group"])
          |> Enum.map(fn {group, members} -> {group, Enum.sum(Enum.map(members, & &1["v"]))} end)
          |> Enum.filter(fn {_group, total} -> total > 50 end)
          |> Enum.sort_by(fn {group, _total} -> group end)
          |> Enum.take(2)
          |> Enum.map(fn {group, total} -> %{"group" => group, "total" => total} end)

        assert rows_out == expected
      end)
    end

    test "a HAVING aggregate absent from select is still tracked at its own plan position" do
      with_chunk_size(3, fn ->
        # `count(v)` never appears in `select` -- it's only reachable
        # through `having_calls`, exercising a plan slot the build side
        # (`new_group`/`update_group`) and the `select`-driven read side
        # (`finalize_body_item`) never share, so a position mix-up
        # between them (e.g. `sum(v)`'s slot vs `count(v)`'s slot) can't
        # be masked by both reading the same index by accident.
        # Deliberately uneven group sizes ("a": 2, "b": 5, "c": 4, "d": 1)
        # so the `count(v) > 3` filter actually excludes some groups
        # rather than passing everything through unconditionally.
        rows =
          for {group, v} <- [
                {"a", 1},
                {"b", 2},
                {"a", 3},
                {"c", 4},
                {"b", 5},
                {"d", 6},
                {"c", 7},
                {"b", 8},
                {"c", 9},
                {"b", 10},
                {"c", 11},
                {"b", 12}
              ],
              do: %{"group" => group, "v" => v}

        query = %Query{
          source: ["items"],
          group_bys: [["group"]],
          havings: [{:cmp, :gt, {:call, "count", [{:field, ["v"]}]}, 3}],
          order_bys: [{["group"], :asc}],
          select: [
            {:field, ["group"]},
            {:computed, "total", {:call, "sum", [{:field, ["v"]}]}}
          ]
        }

        assert {:ok, rows_out} = run(query, %{["items"] => rows})

        expected =
          rows
          |> Enum.group_by(& &1["group"])
          |> Enum.filter(fn {_group, members} -> length(members) > 3 end)
          |> Enum.map(fn {group, members} ->
            %{"group" => group, "total" => Enum.sum(Enum.map(members, & &1["v"]))}
          end)
          |> Enum.sort_by(& &1["group"])

        assert rows_out == expected
      end)
    end

    test "a WHERE clause filters correctly before grouping, across chunk boundaries" do
      with_chunk_size(3, fn ->
        rows = for i <- 1..40, do: %{"v" => i}

        query = %Query{
          source: ["items"],
          wheres: [{:cmp, :gt, ["v"], 20}],
          select: [{:computed, "n", {:call, "count", [{:field, ["v"]}]}}]
        }

        assert {:ok, [%{"n" => 20}]} = run(query, %{["items"] => rows})
      end)
    end

    test "zero matching rows still produces the well-defined single flat-aggregate row" do
      with_chunk_size(3, fn ->
        rows = for i <- 1..10, do: %{"v" => i}

        query = %Query{
          source: ["items"],
          wheres: [{:cmp, :gt, ["v"], 999}],
          select: [
            {:computed, "n", {:call, "count", [{:field, ["v"]}]}},
            {:computed, "total", {:call, "sum", [{:field, ["v"]}]}}
          ]
        }

        assert {:ok, [%{"n" => 0, "total" => nil}]} = run(query, %{["items"] => rows})
      end)
    end
  end

  describe "hard errors surface as ordinary, catchable exceptions -- never a process crash" do
    test "a nil aggregate operand deep in a later chunk still raises normally in the calling process" do
      with_chunk_size(2, fn ->
        # Chunks 1-2 (rows 1-4) are clean; the nil lands in chunk 3.
        rows = [
          %{"v" => 1},
          %{"v" => 2},
          %{"v" => 3},
          %{"v" => 4},
          %{"v" => nil},
          %{"v" => 6}
        ]

        query = %Query{
          source: ["items"],
          select: [{:computed, "total", {:call, "sum", [{:field, ["v"]}]}}]
        }

        assert_raise ArgumentError, ~r/aggregate sum\(\.\.\.\) encountered a nil value/, fn ->
          run(query, %{["items"] => rows})
        end

        # The test process itself must still be alive and responsive --
        # a *linked* task's crash would have taken it down instead.
        assert Process.alive?(self())
      end)
    end

    test "the error surfaces even when many more chunks remain queued behind the failing one" do
      with_chunk_size(2, fn ->
        rows =
          List.duplicate(%{"v" => 1}, 200) ++ [%{"v" => nil}] ++ List.duplicate(%{"v" => 1}, 200)

        query = %Query{
          source: ["items"],
          select: [{:computed, "total", {:call, "sum", [{:field, ["v"]}]}}]
        }

        assert_raise ArgumentError, fn -> run(query, %{["items"] => rows}) end
        assert Process.alive?(self())
      end)
    end
  end

  describe "resource cleanup through the parallel path" do
    test "a Stream.resource/3-backed source's own after_fun still runs on natural exhaustion" do
      with_chunk_size(3, fn ->
        {:ok, agent} = Agent.start_link(fn -> false end)
        rows = for i <- 1..25, do: %{"v" => i}

        query = %Query{
          source: ["items"],
          select: [{:computed, "total", {:call, "sum", [{:field, ["v"]}]}}]
        }

        assert {:ok, cursor} = Executor.run(query, ResourceEngine, {rows, agent})
        assert Cursor.to_list(cursor) == [%{"total" => Enum.sum(1..25)}]
        assert Agent.get(agent, & &1)
      end)
    end

    test "the after_fun still runs even when a later chunk raises" do
      with_chunk_size(2, fn ->
        {:ok, agent} = Agent.start_link(fn -> false end)
        rows = [%{"v" => 1}, %{"v" => 2}, %{"v" => nil}, %{"v" => 4}]

        query = %Query{
          source: ["items"],
          select: [{:computed, "total", {:call, "sum", [{:field, ["v"]}]}}]
        }

        assert_raise ArgumentError, fn ->
          query |> Executor.run(ResourceEngine, {rows, agent}) |> materialize()
        end

        Process.sleep(20)
        assert Agent.get(agent, & &1)
      end)
    end
  end

  describe "property: parallel accumulation always matches an independent reference" do
    property "sum/count/avg/min/max per group match Enum.group_by/2 + Enum.reduce/3" do
      check all(
              rows <-
                list_of(
                  map(
                    {integer(0..4), integer(-100..100)},
                    fn {group, v} -> %{"group" => group, "v" => v} end
                  ),
                  min_length: 1,
                  max_length: 80
                )
            ) do
        with_chunk_size(5, fn ->
          query = %Query{
            source: ["items"],
            group_bys: [["group"]],
            select: [
              {:field, ["group"]},
              {:computed, "n", {:call, "count", [{:field, ["v"]}]}},
              {:computed, "total", {:call, "sum", [{:field, ["v"]}]}},
              {:computed, "lo", {:call, "min", [{:field, ["v"]}]}},
              {:computed, "hi", {:call, "max", [{:field, ["v"]}]}}
            ]
          }

          assert {:ok, rows_out} = run(query, %{["items"] => rows})

          expected =
            rows
            |> Enum.group_by(& &1["group"])
            |> Enum.map(fn {group, members} ->
              values = Enum.map(members, & &1["v"])

              %{
                "group" => group,
                "n" => length(members),
                "total" => Enum.sum(values),
                "lo" => Enum.min(values),
                "hi" => Enum.max(values)
              }
            end)

          assert Enum.sort_by(rows_out, & &1["group"]) == Enum.sort_by(expected, & &1["group"])
        end)
      end
    end
  end
end
