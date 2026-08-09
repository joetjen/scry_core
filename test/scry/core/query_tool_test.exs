defmodule Scry.Core.QueryToolTest do
  @moduledoc """
  `Scry.Core.QueryTool` -- the config-driven resolution/execution/
  formatting logic behind `mix scry.query`/`mix scry.iex`. Covers
  `resolve_parser/1`'s CLI-override-vs-config-vs-default fallback,
  `resolve_backend/1`'s CLI-override-vs-default-vs-sole-backend-vs-
  ambiguous/missing-error behavior, and `run/3`/`execute/2`'s real
  parse+execute+materialize path against `Scry.Core.Test.
  ReferenceEngine` (this package's own generic in-repo test engine --
  a real backend package like `scry_engine_inmemory` can't be a
  dependency here without a cycle).

  Every test that touches `:scry_core, :query_tool` config resets it
  via `on_exit/1` -- `Application.get_env/3`'s own backing application
  environment is a shared, mutable, process-independent global, so a
  leftover value from one test would otherwise leak into the next
  regardless of `async`.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.QueryTool
  alias Scry.Core.Test.ReferenceEngine

  setup do
    on_exit(fn -> Application.delete_env(:scry_core, :query_tool) end)
  end

  defp put_config(config), do: Application.put_env(:scry_core, :query_tool, config)

  describe "resolve_parser/1" do
    test "with no CLI value and no config, defaults to Scry.Core" do
      assert QueryTool.resolve_parser(nil) == {:ok, Scry.Core}
    end

    test "with no CLI value, uses the configured parser" do
      put_config(parser: Scry.Core.QueryToolTest)

      assert QueryTool.resolve_parser(nil) == {:ok, Scry.Core.QueryToolTest}
    end

    test "a CLI value overrides the configured parser when it names a loadable module" do
      put_config(parser: Scry.Core.QueryToolTest)

      assert QueryTool.resolve_parser("Scry.Core") == {:ok, Scry.Core}
    end

    test "a CLI value naming a nonexistent module is a clear error" do
      assert {:error, message} = QueryTool.resolve_parser("NoSuchModuleAtAll")
      assert message =~ "NoSuchModuleAtAll"
    end
  end

  describe "resolve_backend/1" do
    test "zero backends configured is an onboarding error, not a crash" do
      assert {:error, message} = QueryTool.resolve_backend(nil)
      assert message =~ "no backends configured"
      assert message =~ "config :scry_core, :query_tool"
    end

    test "exactly one configured backend is used implicitly, with no CLI value or default" do
      put_config(backends: %{"only" => {__MODULE__, :fake_conn}})

      assert QueryTool.resolve_backend(nil) == {:ok, {ReferenceEngine, %{}}}
    end

    test "multiple backends with no CLI value and no default is an ambiguous-choice error" do
      put_config(
        backends: %{
          "a" => {__MODULE__, :fake_conn},
          "b" => {__MODULE__, :fake_conn}
        }
      )

      assert {:error, message} = QueryTool.resolve_backend(nil)
      assert message =~ "a, b"
    end

    test "multiple backends with a configured default resolves to that default" do
      put_config(
        default: "b",
        backends: %{
          "a" => {__MODULE__, :fake_conn},
          "b" => {__MODULE__, :fake_conn}
        }
      )

      assert QueryTool.resolve_backend(nil) == {:ok, {ReferenceEngine, %{}}}
    end

    test "a CLI value overrides the configured default" do
      put_config(
        default: "a",
        backends: %{
          "a" => {__MODULE__, :fake_conn},
          "b" => {__MODULE__, :other_fake_conn}
        }
      )

      assert QueryTool.resolve_backend("b") == {:ok, {ReferenceEngine, %{other: true}}}
    end

    test "an unknown CLI backend name is a clear error listing the real configured names" do
      put_config(backends: %{"a" => {__MODULE__, :fake_conn}, "b" => {__MODULE__, :fake_conn}})

      assert {:error, message} = QueryTool.resolve_backend("nope")
      assert message =~ "unknown --backend nope"
      assert message =~ "a, b"
    end
  end

  describe "run/3 and execute/2" do
    setup do
      data = %{["users"] => [%{"id" => 1, "name" => "Alice"}, %{"id" => 2, "name" => "Bob"}]}
      {:ok, backend: {ReferenceEngine, data}}
    end

    test "run/3 parses source with the given parser and returns plain-map rows", %{
      backend: backend
    } do
      assert QueryTool.run(~s(SELECT users WHERE id = 1 { name }), Scry.Core, backend) ==
               {:ok, [%{"name" => "Alice"}]}
    end

    test "run/3 folds a parse failure into {:error, reason}", %{backend: backend} do
      assert {:error, _reason} = QueryTool.run("NOT A REAL QUERY", Scry.Core, backend)
    end

    test "execute/2 runs an already-parsed query directly", %{backend: backend} do
      {:ok, query} = Scry.Core.parse(~s(SELECT users { name }))

      assert {:ok, rows} = QueryTool.execute(query, backend)
      assert Enum.sort_by(rows, & &1["name"]) == [%{"name" => "Alice"}, %{"name" => "Bob"}]
    end

    test "execute/2 folds an unknown source into {:error, reason}", %{backend: backend} do
      {:ok, query} = Scry.Core.parse(~s(SELECT no_such_source { name }))

      assert {:error, _reason} = QueryTool.execute(query, backend)
    end

    test "execute/2 calls the configured :executor instead of the Scry.Core.Executor default", %{
      backend: backend
    } do
      put_config(executor: {__MODULE__.FakeExecutor, :run})
      {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 1 { name }))

      assert {:ok, [row]} = QueryTool.execute(query, backend)
      assert row["via_fake_executor"] == true
    end
  end

  describe "format_error/1" do
    test "formats a single %Ichor.Error{} via its own format/1" do
      {:error, error} = Scry.Core.parse("NOT A REAL QUERY")

      assert QueryTool.format_error(error) == Ichor.Error.format(error)
    end

    test "formats a list of %Ichor.Error{} by joining each one's own format/1" do
      {:error, error} = Scry.Core.parse("NOT A REAL QUERY")

      assert QueryTool.format_error([error, error]) ==
               Enum.map_join([error, error], "\n", &Ichor.Error.format/1)
    end

    test "falls back to a plain string unchanged" do
      assert QueryTool.format_error("already a message") == "already a message"
    end

    test "falls back to inspect/1 for anything else" do
      assert QueryTool.format_error({:no_such_source, "widgets"}) ==
               inspect({:no_such_source, "widgets"})
    end
  end

  def fake_conn, do: {ReferenceEngine, %{}}
  def other_fake_conn, do: {ReferenceEngine, %{other: true}}

  defmodule FakeExecutor do
    @moduledoc """
    A stand-in for a kind-specific executor (`Scry.TimeSeries.Executor`,
    e.g.) -- proves `Scry.Core.QueryTool.execute/2` actually calls
    whatever `{module, function}` is configured, not just the
    `Scry.Core.Executor` default it happens to delegate to internally.
    """
    def run(query, engine, conn) do
      with {:ok, cursor} <- Scry.Core.Executor.run(query, engine, conn) do
        rows =
          cursor
          |> Scry.Core.Cursor.to_list()
          |> Enum.map(&Map.put(&1, "via_fake_executor", true))

        {:ok, Scry.Core.Cursor.new(rows)}
      end
    end
  end
end
