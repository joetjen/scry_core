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
  """

  @type predicate ::
          {:cmp, :eq | :not_eq | :lt | :gt | :le | :ge, path :: [String.t()], literal :: term()}
          | {:in, path :: [String.t()], values :: [term()]}
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
            select: [],
            variant: %{}
end
