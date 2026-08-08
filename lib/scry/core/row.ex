defmodule Scry.Core.Row do
  @moduledoc """
  A compact, positional row representation -- a shared column-name-to-
  index map (built *once* per fetch, the same map value reused across
  every row from that fetch) paired with a plain values tuple. Exists
  to let an adapter backed by a genuinely columnar source (a SQL
  engine's own row-major result set, e.g. `Scry.Engine.Exqlite`) skip
  building a brand-new string-keyed map for every single row -- real,
  measured cost at scale, dominated by the per-row `Map.new/1`
  allocation, not by anything `Scry.Core.Executor` itself does with the
  data once it has it.

  `Scry.Core.QueryOps`'s own row-field lookup (`get_path_in/2`) is the
  *only* place in that module which ever reads a row's fields directly
  (confirmed by direct source audit, not assumed) -- so this type only
  needs clauses there to be usable everywhere else in the toolkit
  (`WHERE` evaluation, `GROUP BY` keys, sorting, projection) without
  any of those call sites needing to know or care which row shape they
  were handed.

  **Deliberately not a drop-in, silently-compatible replacement for a
  plain map**: `fetch!/2` *raises* on a column not present in the
  index, rather than returning `nil` the way `Map.get/2` (what a plain
  map row goes through) would. This is an intentional asymmetry, not
  an oversight -- an engine constructing a `Scry.Core.Row` owns its own
  index entirely (which columns it decided to fetch, based on whatever
  it can determine from the query it's compiling), so a lookup miss
  here can only mean that engine's own construction under-collected a
  genuinely-needed column, a real bug in that engine. Turning that into
  a loud, immediate crash (caught by tests and integration runs)
  instead of a silently wrong `nil` flowing through `WHERE`/
  aggregation/projection is the safety net that makes column pruning
  trustworthy at all.

  Only ever constructed by an engine's own `Scry.Core.EngineBehaviour.
  execute/3` implementation, entirely at that engine's own discretion
  (`Scry.Engine.Exqlite`'s own column-pruned fetch, for instance) -- an
  engine that returns plain maps never produces one of these, and
  nothing about a plain-map-returning engine changes.
  """

  @enforce_keys [:index, :values]
  defstruct [:index, :values]

  @typedoc "Column name -> position in `values`, shared across every row from the same fetch."
  @type index :: %{optional(String.t()) => non_neg_integer()}

  @type t :: %__MODULE__{index: index(), values: tuple()}

  @doc """
  Builds the shared column index for a fetch -- call this **once** per
  fetch (per prepared statement's own column list), never per row:
  building it per row would cost as much as the `Map.new/1` allocation
  this whole representation exists to avoid.
  """
  @spec build_index([String.t()]) :: index()
  def build_index(columns) do
    columns
    |> Enum.with_index()
    |> Map.new()
  end

  @doc """
  Wraps one row's positional `values` (a list straight from the
  underlying driver, or an already-built tuple) together with a
  previously-built `index/0`. Cheap: no hashing, no per-row map
  allocation -- just a tuple and a shared reference.
  """
  @spec new(index(), [term()] | tuple()) :: t()
  def new(index, values) when is_list(values), do: new(index, List.to_tuple(values))
  def new(index, values) when is_tuple(values), do: %__MODULE__{index: index, values: values}

  @doc """
  Reads `column` off `row`. Raises `KeyError` if `column` isn't in
  `row`'s own index -- see this module's moduledoc for why that's a
  deliberate, load-bearing asymmetry from a plain map row's `nil`-on-
  miss behavior, not a bug.
  """
  @spec fetch!(t(), String.t()) :: term()
  def fetch!(%__MODULE__{index: index, values: values}, column) do
    case Map.fetch(index, column) do
      {:ok, position} -> elem(values, position)
      :error -> raise KeyError, key: column, term: values
    end
  end

  @doc "Converts `row` to an ordinary string-keyed map -- for tests/debugging, or wherever a real map is genuinely needed (e.g. window-function synthetic-field augmentation, which appends a key no fixed-shape positional row can)."
  @spec to_map(t()) :: %{optional(String.t()) => term()}
  def to_map(%__MODULE__{index: index, values: values}) do
    Map.new(index, fn {column, position} -> {column, elem(values, position)} end)
  end
end
