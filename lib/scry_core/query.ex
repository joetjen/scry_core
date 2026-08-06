defmodule ScryCore.Query do
  @moduledoc """
  The shared target both Scry front ends converge on -- the text grammar
  (`priv/grammar.aether` + `ScryCore.Actions`) and, eventually, the
  Elixir-native builder (impl_spec.md §7: a macro DSL plus a composable
  functional API, neither implemented yet). Adapters and tier-4
  extensions only ever see this struct; neither knows or needs to know
  which front end produced it.

  Field shapes here match the full design in impl_spec.md §7, not just
  what `priv/grammar.aether`'s current Phase 1 subset can populate.
  `group_bys`/`havings`/`distinct`/`order_bys`/`limit`/`offset` are all
  populated now (the full lang_spec.md §5.2 header-modifier chain,
  minus `group by ... rollup`/`... cube`); `group_mode` is the one
  exception still stuck at its `:plain` default either way -- rollup/cube
  aren't in the grammar yet, so nothing ever sets it to anything else.
  `variant` is the extension slot an EP1(b)/(c)/(d)-shaped construct from
  a loaded kind populates (impl_spec.md §2); core itself never writes to
  it.

  `wheres` is a list, combined with `and`, even though the current
  grammar only ever produces zero or one entry (one `WHERE` clause per
  `select`, lang_spec.md §5.2) -- matching the composable builder API's
  eventual ability to push more than one (`ScryCore.Query.where/2`,
  impl_spec.md §7), not a speculative field with nothing behind it.

  A `select` entry is one of three shapes -- a plain field path, a
  nested query (`priv/grammar.aether`'s `body_item := select | ...`,
  ordinary PEG recursion, no extension point needed), or a kind's own
  EP1(b)/(c)/(d) body-item construct, tagged `:variant` and left
  unexamined by core the same way `variant` itself is. A nested query
  is `t()` directly, not wrapped in its own tag -- already
  self-describing via its struct, unlike the other two shapes.

  `predicate()`'s own `{:field, path}` (lang_spec.md §5.9: a
  comparison's right-hand side may be another field path, not just a
  literal) reuses the exact same tag `body_item()` uses above --
  structurally identical in both places (a path naming a field), just
  a predicate operand here instead of an output-projection marker.
  Worth knowing they're the same tag in two conceptually distinct
  positions, not two coincidentally-identical ones.

  `required` (lang_spec.md §6, "Correlation and joins") is meaningful
  only when this query is itself a nested body item -- it's read
  entirely by the *enclosing* query's own projection step (whether to
  drop the outer row when this one comes back empty), never by
  anything in this query's own pipeline. A top-level query's own
  `required` is simply never read by anything; don't go looking for
  where `ScryCore.Executor.run/3` checks its own flag, because it
  doesn't -- only a parent's view of a child's `required` matters.

  `rhs`/`values`'s own `{:param, name}` (lang_spec.md §5.7/§9) is a
  placeholder, not a value -- parsing never resolves it, since the real
  value is supplied separately, at execution time, via
  `ScryCore.Executor.run/4`'s own `params` argument.
  """

  @type predicate ::
          {:cmp, :eq | :not_eq | :lt | :gt | :le | :ge | :match, path :: [String.t()],
           rhs :: term() | {:field, [String.t()]} | {:param, String.t()}}
          | {:in, path :: [String.t()], values :: [term() | {:param, String.t()}]}
          | {:and, predicate(), predicate()}
          | {:or, predicate(), predicate()}
          | {:not, predicate()}

  @type body_item :: {:field, [String.t()]} | t() | {:variant, term()}

  @type t :: %__MODULE__{
          source: [String.t()] | nil,
          wheres: [predicate()],
          group_bys: [[String.t()]],
          group_mode: :plain | :rollup | :cube,
          havings: [predicate()],
          distinct: boolean(),
          order_bys: [{[String.t()], :asc | :desc}],
          limit: non_neg_integer() | nil,
          offset: non_neg_integer() | nil,
          required: boolean(),
          select: [body_item()],
          variant: %{optional(atom()) => term()}
        }

  defstruct source: nil,
            wheres: [],
            group_bys: [],
            group_mode: :plain,
            havings: [],
            distinct: false,
            order_bys: [],
            limit: nil,
            offset: nil,
            required: false,
            select: [],
            variant: %{}
end
