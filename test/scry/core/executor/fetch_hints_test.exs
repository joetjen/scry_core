defmodule Scry.Core.Executor.FetchHintsTest do
  @moduledoc """
  End-to-end wiring for `EngineBehaviour.fetch/4`: dispatch preference
  (`fetch/4` > `fetch/3` > `fetch/2`), `opts.columns` actually carrying
  what `referenced_top_level_fields/2` computed (unit-tested in
  isolation in `referenced_top_level_fields_test.exs` -- this file
  proves the *wiring*, not the AST analysis itself), and -- the part
  that actually matters -- that `Scry.Core.Row`-shaped rows flow
  transparently through the *entire* pipeline (`WHERE`, `GROUP BY`,
  `ORDER BY`, `DISTINCT`, projection, and correlated nested-`SELECT`
  scope resolution, where an *ancestor's* row can itself be a `Row`)
  and produce byte-identical output to the same query against
  plain-map rows.

  `HintedRowEngine` below is deliberately built the same way a real
  adapter (`Scry.Engine.Exqlite`) is expected to behave: it honors
  `opts.columns` by actually pruning to exactly those columns (or every
  column, for `:unknown`) and hands back `Scry.Core.Row` values, not
  maps -- so a bug in `referenced_top_level_fields/2` that
  under-collects a genuinely-needed column surfaces here as a loud
  `KeyError` (`Row.fetch!/2`'s own deliberate raise-on-miss), not a
  silently wrong result -- exactly the safety net this whole feature
  was designed around.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Core.{Cursor, Executor, Query, Row}

  defmodule MapEngine do
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

  defmodule PreferenceEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch(_data, _source), do: {:error, :fetch2_should_not_be_called}

    @impl true
    def fetch(_data, _source, _query), do: {:error, :fetch3_should_not_be_called}

    @impl true
    def fetch(data, source, _query, _opts) do
      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end
  end

  defmodule RecordingEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch({data, _agent}, source) do
      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end

    @impl true
    def fetch({data, agent}, source, _query, opts) do
      Agent.update(agent, fn acc -> [{source, opts} | acc] end)

      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, rows}
        :error -> {:error, {:no_such_source, source}}
      end
    end
  end

  defmodule HintedRowEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def fetch(data, source), do: fetch(data, source, nil, %{columns: :unknown})

    @impl true
    def fetch(data, source, _query, opts) do
      case Map.fetch(data, source) do
        {:ok, rows} -> {:ok, to_rows(rows, opts[:columns] || :unknown)}
        :error -> {:error, {:no_such_source, source}}
      end
    end

    defp to_rows([], _columns_hint), do: []

    defp to_rows(rows, columns_hint) do
      all_columns = rows |> hd() |> Map.keys() |> Enum.sort()

      columns =
        case columns_hint do
          {:ok, set} -> MapSet.to_list(set)
          :unknown -> all_columns
        end

      index = Row.build_index(columns)
      Enum.map(rows, fn row -> Row.new(index, Enum.map(columns, &Map.get(row, &1))) end)
    end
  end

  defp materialize({:ok, cursor}), do: {:ok, Cursor.to_list(cursor)}
  defp materialize({:error, _} = err), do: err

  defp run(query, engine, data), do: query |> Executor.run(engine, data) |> materialize()

  describe "dispatch preference" do
    test "fetch/4 is preferred over fetch/3 and fetch/2 when all three are implemented" do
      query = %Query{source: ["items"], select: [{:field, ["id"]}]}
      data = %{["items"] => [%{"id" => 1}]}
      assert {:ok, [%{"id" => 1}]} = run(query, PreferenceEngine, data)
    end
  end

  describe "opts.columns actually carries what referenced_top_level_fields/2 computed" do
    test "an eligible plain query gets {:ok, columns}" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      query = %Query{
        source: ["items"],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["name"]}]
      }

      data = {%{["items"] => [%{"status" => "active", "name" => "a"}]}, agent}
      assert {:ok, _} = run(query, RecordingEngine, data)

      assert {["items"], %{columns: {:ok, columns}}} =
               Enum.find(Agent.get(agent, & &1), fn {source, _opts} -> source == ["items"] end)

      assert columns == MapSet.new(["status", "name"])
    end

    test "a query with a nested SELECT gets :unknown for its own (outer) source" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      query = %Query{
        source: ["users"],
        select: [
          {:field, ["id"]},
          %Query{source: ["orders"], select: [{:field, ["total"]}]}
        ]
      }

      data = {%{["users"] => [%{"id" => 1}], ["orders"] => [%{"total" => 5}]}, agent}
      assert {:ok, _} = run(query, RecordingEngine, data)

      assert {["users"], %{columns: :unknown}} =
               Enum.find(Agent.get(agent, & &1), fn {source, _opts} -> source == ["users"] end)
    end

    test "a query with a window function gets :unknown" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      query = %Query{
        source: ["items"],
        select: [
          {:computed, "r", {:window, {:call, "row_number", []}, [["grp"]], [{["v"], :desc}], nil}}
        ]
      }

      data = {%{["items"] => [%{"grp" => 1, "v" => 1}]}, agent}
      assert {:ok, _} = run(query, RecordingEngine, data)

      assert {["items"], %{columns: :unknown}} =
               Enum.find(Agent.get(agent, & &1), fn {source, _opts} -> source == ["items"] end)
    end
  end

  describe "Scry.Core.Row rows flow transparently through the full pipeline" do
    test "plain WHERE + projection" do
      rows = [%{"id" => 1, "status" => "active"}, %{"id" => 2, "status" => "inactive"}]

      query = %Query{
        source: ["items"],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, [%{"id" => 1}]} = run(query, HintedRowEngine, %{["items"] => rows})
    end

    test "GROUP BY + aggregate" do
      rows = for i <- 1..6, do: %{"id" => i, "grp" => rem(i, 2), "v" => i}

      query = %Query{
        source: ["items"],
        group_bys: [["grp"]],
        select: [{:field, ["grp"]}, {:computed, "total", {:call, "sum", [{:field, ["v"]}]}}]
      }

      assert {:ok, rows_out} = run(query, HintedRowEngine, %{["items"] => rows})

      assert Enum.sort_by(rows_out, & &1["grp"]) == [
               %{"grp" => 0, "total" => 12},
               %{"grp" => 1, "total" => 9}
             ]
    end

    test "ORDER BY sorts correctly against Row-shaped rows" do
      rows = [%{"id" => 3}, %{"id" => 1}, %{"id" => 2}]
      query = %Query{source: ["items"], order_bys: [{["id"], :asc}], select: [{:field, ["id"]}]}

      assert {:ok, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]} =
               run(query, HintedRowEngine, %{["items"] => rows})
    end

    test "DISTINCT dedups correctly" do
      rows = [%{"status" => "a"}, %{"status" => "a"}, %{"status" => "b"}]
      query = %Query{source: ["items"], distinct: true, select: [{:field, ["status"]}]}

      assert {:ok, rows_out} = run(query, HintedRowEngine, %{["items"] => rows})
      assert Enum.sort(rows_out) == [%{"status" => "a"}, %{"status" => "b"}]
    end

    test "correlated nested SELECT resolves an ancestor's own field when the ancestor row is itself a Row" do
      users = for i <- 1..3, do: %{"id" => i, "name" => "u#{i}"}
      orders = for i <- 1..3, do: %{"user_id" => i, "total" => i * 10}

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

      assert {:ok, rows_out} =
               run(query, HintedRowEngine, %{["users"] => users, ["orders"] => orders})

      assert length(rows_out) == 3

      assert Enum.all?(rows_out, fn row ->
               row["orders"] == [%{"total" => row["id"] * 10}]
             end)
    end

    test "a column on the nested source sharing a name with the outer's own_name is still its own column (single-segment rule)" do
      users = [%{"id" => 1}]
      # `orders`' own rows have a genuine column literally named "users"
      # -- colliding with the outer query's own `own_name`. A bare
      # single-segment `{:field, ["users"]}` inside the nested query's
      # own select must still resolve to *this row's own* "users"
      # column, never be excluded as if it referred to the ancestor.
      orders = [%{"user_id" => 1, "users" => "not-a-qualifier"}]

      query = %Query{
        source: ["users"],
        select: [
          {:field, ["id"]},
          %Query{
            source: ["orders"],
            wheres: [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}],
            select: [{:field, ["users"]}]
          }
        ]
      }

      assert {:ok, rows_out} =
               run(query, HintedRowEngine, %{["users"] => users, ["orders"] => orders})

      assert rows_out == [%{"id" => 1, "orders" => [%{"users" => "not-a-qualifier"}]}]

      assert run(query, HintedRowEngine, %{["users"] => users, ["orders"] => orders}) ==
               run(query, MapEngine, %{["users"] => users, ["orders"] => orders})
    end
  end

  describe "property: fetch/4 (pruned + compact Row) always matches fetch/2 (baseline maps)" do
    property "byte-identical output across several eligible query shapes and random row data" do
      check all(
              shape <- member_of([:plain_filter, :group_by, :in_with_field]),
              rows <-
                list_of(
                  map(
                    {integer(0..20), member_of(["active", "inactive", "pending"]),
                     integer(-50..50)},
                    fn {id, status, v} -> %{"id" => id, "status" => status, "v" => v} end
                  ),
                  max_length: 40
                )
            ) do
        query =
          case shape do
            :plain_filter ->
              %Query{
                source: ["items"],
                wheres: [{:cmp, :eq, ["status"], "active"}],
                select: [{:field, ["id"]}, {:field, ["v"]}]
              }

            :group_by ->
              %Query{
                source: ["items"],
                group_bys: [["status"]],
                select: [
                  {:field, ["status"]},
                  {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
                ]
              }

            :in_with_field ->
              %Query{
                source: ["items"],
                wheres: [{:in, ["status"], ["active", "pending"]}],
                select: [{:field, ["id"]}]
              }
          end

        data = %{["items"] => rows}
        baseline = run(query, MapEngine, data)
        candidate = run(query, HintedRowEngine, data)

        assert baseline == candidate
      end
    end
  end
end
