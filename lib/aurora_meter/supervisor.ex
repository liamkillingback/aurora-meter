defmodule AuroraMeter.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: AuroraMeter.Registry},
      # First, and it supervises nothing at rest. It exists so that a host
      # callback the library invokes runs in a process of its own: a callback
      # that raises must not take its caller down, and one that never returns
      # must be killable. `Task.async/1` links, which would give a raising
      # callback the caller's process.
      {Task.Supervisor, name: AuroraMeter.TaskSupervisor},
      AuroraMeter.Store,
      # Immediately after the Store: a durable write is admitted before it
      # touches a connection, and a caller that is refused must be refused
      # rather than queued behind a pool checkout.
      AuroraMeter.Events.Gate,
      AuroraMeter.Cluster,
      AuroraMeter.Flusher,
      AuroraMeter.Broadcaster,
      # Last, and deliberately: the post-start checks need the rest of the tree
      # up, and they return `:ignore` so nothing is left running.
      AuroraMeter.BootChecks
    ]

    # **The restart intensity is chosen here rather than inherited**
    # (`open-findings.md` X354). Until this line carried the two options the
    # tree took OTP's default of three restarts in five seconds, which is a
    # number nobody picked for these children.
    #
    # The choice turns on an asymmetry. Restarting a child of this tree is
    # cheap: `init/1` creates ETS tables, subscribes to one PubSub topic and
    # schedules a timer, and none of them does any IO that can block. Giving up
    # is not cheap at all: when this supervisor terminates, the Store dies with
    # it and the unflushed buffer in its ETS tables is **gone**, metering stops
    # entirely, and the failure is handed to the host's own supervisor, which in
    # an ordinary Phoenix tree at OTP's defaults can take the whole application
    # down. So the cost of tolerating one more restart is some wasted CPU, and
    # the cost of one fewer is lost usage and an outage. Ten in sixty seconds
    # leans the whole way towards tolerating the flap.
    #
    # It still gives up on a genuinely permanent failure, which is the thing an
    # intensity is for: a child that cannot start at all restarts as fast as the
    # supervisor can spawn it and spends ten in a few milliseconds. What the
    # wider window buys is the other shape, a child that dies every half minute
    # under load, which used to escalate into a total outage on the third one
    # and now does not.
    #
    # **When the tree does give up**, metering has stopped and the buffered
    # deltas are lost, exactly as the `AuroraMeter.Flusher` moduledoc describes
    # for a VM loss. A host is expected to let its own supervisor restart
    # `AuroraMeter` (counters rehydrate lazily from the database, so the loss is
    # bounded by one flush interval, not by the whole period) and to treat the
    # crash reports that preceded it as the incident: the tree going down is the
    # symptom and the repeatedly dying child is the cause. A host that cannot
    # afford the loss at all should be recording durable events
    # (`AuroraMeter.record/4`) rather than relying on the buffered path.
    #
    # `AuroraMeter.KillTest` asserts how much of this budget the suite spends
    # and is the only other place the number appears; the two move together.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
