defmodule Scry.Core.Executor.ParallelPlainFilterTest do
  @moduledoc """
  `Scry.Core.Executor`'s parallel, chunked plain `WHERE`+projection path
  (`run_plain_parallel/7`, sharing `process_chunks_parallel/4` with the
  streaming-aggregation path) -- confirms it produces byte-identical
  results (row content *and* order) to a single-process sequential scan
  across datasets deliberately spanning many chunks, that a hard error
  deep inside a later chunk still surfaces as an ordinary, catchable
  exception in the calling process rather than crashing it, and that a
  real `Stream.resource/3`-backed source still gets cleaned up
  correctly through this new consumption pattern.

  What this file deliberately does *not* try to mechanically prove:
  that a `LIMIT`-bound query, one with a nested `SELECT` in `select`,
  or one whose `select` is only bare field references never dispatches
  into this path at all -- `run/6`'s own `cond` clause ordering is what
  enforces that (read it directly), and there's no reliable, non-flaky
  way to observe "which private function ran" from a black-box test
  without intrusive production-code instrumentation. What *is* tested
  here: a `LIMIT`-bound query's own early-stop behavior is unchanged
  (`executor/lazy_execution_test.exs`'s pre-existing counting test
  still passes, proving it), and a nested-`SELECT` query's own
  correctness is unaffected by this path existing at all (below) --
  regression coverage, not a dispatch-path proof.

  Every query below wraps its projected field in `string(...)` (via
  `cast_id_select/0`) purely to satisfy `select_has_call?/1` -- the
  path's own eligibility gate, added after measuring that a bare-field
  `select` is genuinely *slower* through this path than through the
  existing sequential one (the per-row copy into a worker's mailbox
  costs more than a bare field access saves), while a `select`
  containing a real function call is where the measured speedup
  actually showed up (`Scry.Core.Executor`'s own moduledoc and
  `CHANGELOG.md` have the numbers). Without a call somewhere in
  `select`, every query here would silently take the sequential
  `run_plain_streaming/7` path instead and this file would stop
  testing what it says it tests.

  Every test here forces a tiny `parallel_chunk_size` (`Application.
  put_env(:scry_core, :parallel_chunk_size, n)`, restored via
  `on_exit`) so a dataset of a few dozen rows genuinely spans several
  chunks. `async: false`: `parallel_chunk_size`/`parallel_max_
  concurrency` are process-global `Application` env, and no other test
  file touches either key concurrently, but mutating global state is
  never safe to run concurrently with itself.

  Expect `[error] Task ... terminating` log lines from the hard-error
  tests below -- `Task.Supervisor`'s own standard crash reporting for a
  worker that raised on purpose, not a sign anything is actually
  broken; the tests themselves assert the calling process survives and
  receives an ordinary, rescuable exception.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Scry.Core.{Cursor, Executor, Query}

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

  # A `string(id)` cast projects `id` under its original key, exactly
  # like `{:field, ["id"]}` would, except now with a real `:call` node
  # in `select` -- satisfies `select_has_call?/1` without changing
  # anything else about what's being tested. Values compared against
  # this project's own output need `to_string/1` accordingly.
  defp cast_id_select, do: [{:computed, "id", {:call, "string", [{:field, ["id"]}]}}]

  describe "correctness and order across chunk boundaries" do
    test "a WHERE filter spanning many chunks matches a hand-computed reference" do
      with_chunk_size(4, fn ->
        rows = for i <- 1..50, do: %{"id" => i, "even" => rem(i, 2) == 0}

        query = %Query{
          source: ["items"],
          wheres: [{:cmp, :eq, ["even"], true}],
          select: cast_id_select()
        }

        assert {:ok, rows_out} = run(query, %{["items"] => rows})

        expected = for i <- 1..50, rem(i, 2) == 0, do: %{"id" => to_string(i)}
        assert Enum.sort_by(rows_out, &String.to_integer(&1["id"])) == expected
      end)
    end

    test "row order exactly matches the original source order -- no sorting applied here" do
      with_chunk_size(3, fn ->
        # Deliberately not in id order in the source, so this only
        # passes if chunk concatenation genuinely preserves fetch
        # order rather than happening to come out sorted anyway.
        rows = [
          %{"id" => 5},
          %{"id" => 1},
          %{"id" => 4},
          %{"id" => 2},
          %{"id" => 3},
          %{"id" => 9},
          %{"id" => 7},
          %{"id" => 8},
          %{"id" => 6}
        ]

        query = %Query{source: ["items"], select: cast_id_select()}

        assert {:ok, rows_out} = run(query, %{["items"] => rows})
        assert rows_out == Enum.map(rows, &%{"id" => to_string(&1["id"])})
      end)
    end

    test "OFFSET (no LIMIT) is still applied correctly after parallel processing" do
      with_chunk_size(3, fn ->
        rows = for i <- 1..20, do: %{"id" => i}
        query = %Query{source: ["items"], offset: 15, select: cast_id_select()}

        assert {:ok, rows_out} = run(query, %{["items"] => rows})
        assert rows_out == for(i <- 16..20, do: %{"id" => to_string(i)})
      end)
    end

    test "zero matching rows produces an empty result, not an error" do
      with_chunk_size(3, fn ->
        rows = for i <- 1..10, do: %{"id" => i}

        query = %Query{
          source: ["items"],
          wheres: [{:cmp, :gt, ["id"], 999}],
          select: cast_id_select()
        }

        assert {:ok, []} = run(query, %{["items"] => rows})
      end)
    end

    test "a nested SELECT in the outer select still produces correct results" do
      with_chunk_size(4, fn ->
        users = for i <- 1..30, do: %{"id" => i}
        orders = for i <- 1..30, do: %{"user_id" => i, "total" => i * 10}

        query = %Query{
          source: ["users"],
          select: [
            {:field, ["id"]},
            %Query{
              source: ["orders"],
              wheres: [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}],
              select: [{:field, ["total"]}]
            }
          ]
        }

        assert {:ok, rows_out} = run(query, %{["users"] => users, ["orders"] => orders})
        assert length(rows_out) == 30

        assert Enum.all?(rows_out, fn row ->
                 row["orders"] == [%{"total" => row["id"] * 10}]
               end)
      end)
    end
  end

  describe "hard errors surface as ordinary, catchable exceptions -- never a process crash" do
    test "an error deep in a later chunk still raises normally in the calling process" do
      with_chunk_size(2, fn ->
        rows = [
          %{"id" => 1, "tag" => "ok"},
          %{"id" => 2, "tag" => "ok"},
          %{"id" => 3, "tag" => "ok"},
          %{"id" => 4, "tag" => "ok"},
          %{"id" => 5, "tag" => "bad"},
          %{"id" => 6, "tag" => "ok"}
        ]

        # `~` against a non-regex right-hand side is a genuine
        # BEAM-level `FunctionClauseError`, not an explicit `raise` --
        # deliberately using this specific failure shape, since it's
        # the one that originally exposed `reduce_chunk_result/3`'s own
        # bug (a raw runtime error reason isn't already an exception
        # struct the way an explicit `raise SomeException` is).
        query = %Query{
          source: ["items"],
          wheres: [{:cmp, :match, ["tag"], "bad"}],
          select: cast_id_select()
        }

        assert_raise FunctionClauseError, fn -> run(query, %{["items"] => rows}) end
        assert Process.alive?(self())
      end)
    end
  end

  describe "resource cleanup through the parallel path" do
    test "a Stream.resource/3-backed source's own after_fun still runs on natural exhaustion" do
      with_chunk_size(3, fn ->
        {:ok, agent} = Agent.start_link(fn -> false end)
        rows = for i <- 1..25, do: %{"id" => i}

        query = %Query{source: ["items"], select: cast_id_select()}

        assert {:ok, cursor} = Executor.run(query, ResourceEngine, {rows, agent})
        assert length(Cursor.to_list(cursor)) == 25
        assert Agent.get(agent, & &1)
      end)
    end
  end

  describe "property: parallel plain filtering always matches an independent reference" do
    property "matches Enum.filter/2 + Enum.map/2 over the same rows, in the same order" do
      check all(
              rows <-
                list_of(
                  map({integer(0..200), boolean()}, fn {id, keep} ->
                    %{"id" => id, "keep" => keep}
                  end),
                  max_length: 60
                )
            ) do
        with_chunk_size(5, fn ->
          query = %Query{
            source: ["items"],
            wheres: [{:cmp, :eq, ["keep"], true}],
            select: cast_id_select()
          }

          assert {:ok, rows_out} = run(query, %{["items"] => rows})

          expected =
            rows
            |> Enum.filter(& &1["keep"])
            |> Enum.map(&%{"id" => to_string(&1["id"])})

          assert rows_out == expected
        end)
      end
    end
  end
end
