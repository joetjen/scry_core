defmodule Scry.Core.Application do
  @moduledoc """
  Starts `Scry.Core.TaskSupervisor`, the supervisor `Scry.Core.Executor`'s
  own parallel chunked-aggregation path (`run_grouped_streaming/7`)
  runs its per-chunk worker tasks under.

  Deliberately a real, named `Task.Supervisor`, not a bare `Task.async/1`
  call -- `Task.Supervisor.async_stream_nolink/4` (unlinked) is what
  lets a worker's own crash (a hard aggregate-nil error, say) surface
  back to whatever process called `Executor.run/4` as an ordinary,
  rescuable exception, exactly like today's single-process code path.
  A *linked* task (plain `Task.async_stream/3`, or any bare
  `Task.async/1`) would instead send an uncatchable `EXIT` signal that
  kills the calling process outright the moment a worker crashes --
  confirmed directly (a real crashing task under each), not assumed.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Task.Supervisor, name: Scry.Core.TaskSupervisor}]
    Supervisor.start_link(children, strategy: :one_for_one, name: Scry.Core.Supervisor)
  end
end
