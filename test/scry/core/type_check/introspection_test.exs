defmodule Scry.Core.TypeCheck.IntrospectionTest do
  use ExUnit.Case, async: true

  alias Scry.Core.{Query, TypeCheck.Introspection}

  defmodule FakeEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def execute(_conn, _query, _params), do: {:error, {:unsupported, :not_implemented}}

    @impl true
    def describe_source({test_pid, schema}, source) do
      send(test_pid, {:describe_source_called, source})

      case Map.fetch(schema, source) do
        {:ok, fields} -> {:ok, fields}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule FailingEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def execute(_conn, _query, _params), do: {:error, {:unsupported, :not_implemented}}

    @impl true
    def describe_source(_conn, _source), do: {:error, {:introspection_error, :connection_lost}}
  end

  defmodule NoIntrospectionEngine do
    @moduledoc false
    @behaviour Scry.Core.EngineBehaviour

    @impl true
    def execute(_conn, _query, _params), do: {:error, {:unsupported, :not_implemented}}
  end

  describe "check_with_introspection/3" do
    test "fills in a totally undeclared source from describe_source/2" do
      schema = %{
        "orders" => [%{name: "age", nullable: true, scalar: :integer}]
      }

      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :gt, ["age"], 30}]
      }

      # No guard for "age" anywhere -- this only fails if the introspected
      # nullable declaration was genuinely merged in and checked, not just
      # fetched and discarded.
      assert {:error, {:unguarded_null_comparison, "orders", "age"}} =
               Introspection.check_with_introspection(query, FakeEngine, {self(), schema})
    end

    test "an already-declared source is never introspected at all" do
      schema = %{"orders" => [%{name: "age", nullable: true, scalar: :integer}]}

      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :gt, ["age"], 30}],
        type_decls: %{
          "orders" => %{name: "orders", kind: nil, fields: [{"age", {:named, "Int", nil}}]}
        }
      }

      assert :ok = Introspection.check_with_introspection(query, FakeEngine, {self(), schema})
      refute_received {:describe_source_called, "orders"}
    end

    test "declaring even one field opts the whole source out of introspection" do
      schema = %{
        "orders" => [
          %{name: "age", nullable: true, scalar: :integer},
          %{name: "total", nullable: true, scalar: :integer}
        ]
      }

      # Only "age" is declared inline; "total" is left undeclared on the
      # same source -- per the documented tradeoff, introspection is
      # never consulted for "total" either, since the source as a whole
      # already has an inline declaration.
      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :gt, ["total"], 10}],
        type_decls: %{
          "orders" => %{name: "orders", kind: nil, fields: [{"age", {:named, "Int", nil}}]}
        }
      }

      assert :ok = Introspection.check_with_introspection(query, FakeEngine, {self(), schema})
      refute_received {:describe_source_called, "orders"}
    end

    test "a WITH binding name is never introspected as a real source" do
      schema = %{"b" => [%{name: "x", nullable: false, scalar: :integer}]}

      bound = %Query{source: ["real_table"], select: []}

      query = %Query{
        source: ["b"],
        select: [],
        with_bindings: %{"b" => bound}
      }

      assert :ok = Introspection.check_with_introspection(query, FakeEngine, {self(), schema})
      refute_received {:describe_source_called, "b"}
    end

    test "{:error, :not_found} is absorbed silently" do
      query = %Query{source: ["ghost"], select: []}

      assert :ok = Introspection.check_with_introspection(query, FakeEngine, {self(), %{}})
      assert_received {:describe_source_called, "ghost"}
    end

    test "{:error, {:introspection_error, _}} aborts the whole check" do
      query = %Query{source: ["orders"], select: []}

      assert {:error, {:introspection_failed, "orders", :connection_lost}} =
               Introspection.check_with_introspection(query, FailingEngine, nil)
    end

    test "an engine with no describe_source/2 at all contributes nothing" do
      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :gt, ["age"], 30}]
      }

      assert :ok = Introspection.check_with_introspection(query, NoIntrospectionEngine, nil)
    end

    test "a non-nullable introspected field needs no guard" do
      schema = %{"orders" => [%{name: "id", nullable: false, scalar: :integer}]}

      query = %Query{
        source: ["orders"],
        select: [],
        wheres: [{:cmp, :eq, ["id"], 1}]
      }

      assert :ok = Introspection.check_with_introspection(query, FakeEngine, {self(), schema})
    end
  end
end
