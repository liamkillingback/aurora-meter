defmodule AuroraMeter.Bench.Modes.Cluster do
  @moduledoc false

  # `cluster_2` and `cluster_4`: convergence and hard-limit overshoot with two
  # or four **real** BEAM nodes sharing one database and one distributed PubSub.
  #
  # Where Erlang distribution cannot start, or a peer cannot be started, the
  # mode **exits non-zero with `reason: "distribution_unavailable"` recorded**.
  # It never falls back to `cluster_2_sim`. A simulation in one VM has one
  # scheduler, one connection pool, one ETS table and one copy of the code, and
  # presenting its number as a cluster result is the exact failure this whole
  # unit exists to stop.
  #
  # What is measured: every node reserves against one shared tenant with a hard
  # limit, so the admissions across the cluster exceed the limit by whatever the
  # other nodes admitted before gossip reached them. The guarantee
  # (`architecture-map.md` section 3) is that the overshoot is bounded by what
  # other nodes admitted within one `broadcast_interval`, one `flush_interval`
  # if gossip was lost, so the bound is **computed from the configured intervals
  # and the measured per-node rate**, never from a number somebody chose.

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3, merge: 1, time: 1]

  alias AuroraMeter.Bench.Mode
  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Runner
  alias AuroraMeter.Bench.Stats

  @period ~U[2026-07-01 00:00:00Z]
  @cookie :aurora_meter_bench

  @impl AuroraMeter.Bench.Mode
  def prepare(ctx) do
    ctx
    |> Map.put(:period, @period)
    |> Map.put(:workload_extra, %{
      # `procs` is the node count here, not `--procs`: this mode's concurrency
      # is one loop per node and `--procs` is not used at all.
      "procs" => Modes.cluster_size(ctx.mode),
      "per_proc" => ctx.per,
      "nodes" => Modes.cluster_size(ctx.mode),
      "tenants" => 1,
      "keys" => 1,
      "limit" => ctx.cluster_limit,
      "contended" => true
    })
    |> add_note(
      "every node reserves against one shared key with a hard limit of #{ctx.cluster_limit}. " <>
        "The overshoot is the admissions above that limit, and the bound it is asserted " <>
        "against is computed from the configured broadcast_interval and the measured " <>
        "per-node rate, not from a constant."
    )
  end

  @impl AuroraMeter.Bench.Mode
  def custom(ctx) do
    case start_peers(ctx) do
      {:ok, peers} -> measure(ctx, peers)
      {:error, reason} -> unavailable(reason)
    end
  end

  @impl AuroraMeter.Bench.Mode
  def verify(_ctx, tally),
    do: Map.get(tally, :cluster_verdict, {false, ["the cluster leg never ran"]})

  # -- distribution -----------------------------------------------------------

  @doc """
  Whether this node can take part in a cluster run, and why not when it cannot.

  Answers `:ok` or `{:error, reason}`. Starting distribution is a side effect,
  so it happens here rather than being assumed anywhere else.
  """
  @spec ensure_distribution() :: :ok | {:error, term()}
  def ensure_distribution do
    cond do
      # The refusal path has to be reachable on a host where distribution DOES
      # work, or it is a branch nobody has ever run and the evidence for
      # "it exits non-zero and records distribution_unavailable" is a reading of
      # the source. It is an environment variable and not a switch on purpose:
      # `--no-distribution` would read as a supported way to run a cluster mode,
      # and there is no such thing.
      System.get_env("AURORA_BENCH_NO_DISTRIBUTION") == "1" ->
        {:error, :disabled_by_environment}

      Node.alive?() ->
        :ok

      true ->
        start_distribution()
    end
  end

  defp start_distribution do
    name = :"aurora_bench_#{System.unique_integer([:positive])}"

    # `name_domain:` and not the bare `:shortnames` atom: `Node.start/2`'s
    # two-atom form is gone in OTP 29 and its options are a keyword list.
    case Node.start(name, name_domain: :shortnames) do
      {:ok, _pid} ->
        Node.set_cookie(@cookie)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp start_peers(ctx) do
    with :ok <- ensure_distribution() do
      Node.set_cookie(@cookie)
      boot_peers(ctx, Modes.cluster_size(ctx.mode) - 1, [])
    end
  end

  defp boot_peers(_ctx, 0, peers), do: {:ok, Enum.reverse(peers)}

  defp boot_peers(ctx, remaining, peers) do
    case boot_peer(ctx, remaining) do
      {:ok, peer} -> boot_peers(ctx, remaining - 1, [peer | peers])
      {:error, reason} -> stop_and_fail(peers, reason)
    end
  end

  defp stop_and_fail(peers, reason) do
    Enum.each(peers, &stop_peer/1)
    {:error, reason}
  end

  defp boot_peer(ctx, index) do
    name = ~c"aurora_bench_peer_#{ctx.short_id}_#{index}"
    args = [~c"-setcookie", Atom.to_charlist(@cookie)] ++ code_path_args()

    case :peer.start(%{name: name, args: args, wait_boot: 30_000}) do
      {:ok, pid, node} -> configure_peer(ctx, pid, node)
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp code_path_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end

  defp configure_peer(ctx, pid, node) do
    case :erpc.call(node, __MODULE__, :boot, [peer_env(ctx)], 60_000) do
      :ok -> {:ok, {pid, node}}
      other -> {:error, {:peer_boot_failed, node, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  @shared_env [
    :pubsub,
    :plans,
    :default_plan,
    :storage,
    :history,
    :feature_sources,
    :flush_interval,
    :broadcast_interval,
    :metrics_interval,
    :period_source,
    :subscription_cache_ttl
  ]

  # A key this node has not set is LEFT UNSET on the peer, not copied as nil.
  # `AuroraMeter.Config` validates with NimbleOptions, and an explicit nil is
  # not the same as an absent key: putting `subscription_cache_ttl: nil` made
  # every peer refuse to boot with "expected non negative integer, got: nil",
  # which the mode then correctly reported as distribution_unavailable for a
  # reason that had nothing to do with distribution.
  defp peer_env(ctx) do
    %{
      repo: ctx.repo,
      repo_config:
        ctx.repo.config()
        |> Keyword.drop([:pool, :name, :telemetry_prefix, :otp_app])
        |> Keyword.put(:pool_size, Runner.cluster_pool_size()),
      env:
        @shared_env
        |> Enum.map(fn key -> {key, Application.get_env(:aurora_meter, key)} end)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  @doc false
  @spec boot(map()) :: :ok | {:error, term()}
  def boot(environment) do
    # The tree is started inside a **held** process rather than in the caller.
    # `:erpc.call/4` runs the call in a transient process on the peer, and
    # `repo.start_link/1`, `Phoenix.PubSub.Supervisor.start_link/1` and
    # `AuroraMeter.start_link/1` all link: when the call returned, that process
    # exited and took the peer's whole supervision tree with it. Measured as a
    # `DBConnection.Holder.checkout` shutdown arriving mid-run, several layers
    # from the cause.
    caller = self()

    spawn(fn ->
      send(caller, {:booted, do_boot(environment)})
      Process.sleep(:infinity)
    end)

    receive do
      {:booted, result} -> result
    after
      60_000 -> {:error, :peer_boot_timeout}
    end
  end

  defp do_boot(%{repo: repo, repo_config: config, env: env}) do
    for app <- [:ecto_sql, :postgrex, :telemetry, :phoenix_pubsub],
        do: {:ok, _started} = Application.ensure_all_started(app)

    for {key, value} <- env, do: Application.put_env(:aurora_meter, key, value)
    Application.put_env(:aurora_meter, :repo, repo)

    children = [
      {repo, Keyword.put(config, :log, false)},
      {Phoenix.PubSub, name: Application.get_env(:aurora_meter, :pubsub)},
      AuroraMeter
    ]

    {:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Peer)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  @spec reserve_loop(String.t(), atom(), DateTime.t(), pos_integer()) :: %{
          admitted: non_neg_integer(),
          denied: non_neg_integer()
        }
  def reserve_loop(tenant, feature, period, count) do
    Enum.reduce(1..count, %{admitted: 0, denied: 0}, fn _n, acc ->
      case AuroraMeter.Entitlements.reserve(tenant, feature, 1, period) do
        :ok -> %{acc | admitted: acc.admitted + 1}
        {:error, _reason} -> %{acc | denied: acc.denied + 1}
      end
    end)
  end

  @doc false
  @spec flush_node() :: String.t()
  def flush_node, do: inspect(AuroraMeter.Flusher.flush())

  @doc false
  @spec read_node(String.t(), atom(), DateTime.t()) :: integer()
  def read_node(tenant, feature, period), do: AuroraMeter.Counter.value(tenant, feature, period)

  # -- the measured phase -----------------------------------------------------

  defp measure(ctx, peers) do
    tenant = Modes.shared_tenant(ctx)
    {:ok, _subscription} = AuroraMeter.subscribe(tenant, :bench_cluster)
    nodes = [node() | Enum.map(peers, &elem(&1, 1))]
    per_node = ctx.per

    {us, results} = time(fn -> run_everywhere(nodes, tenant, per_node) end)

    # The second half of the guarantee, and the half a burst alone cannot show.
    # The overshoot above is what the nodes admitted before gossip reached them;
    # this waits one settling window and then asks every node for one more unit.
    # Every node must refuse. A cluster that overshot and then went on
    # overshooting would satisfy the bound check and be broken.
    Process.sleep(ctx.converge_ms)
    probe = Enum.map(nodes, &probe_node(&1, tenant))

    # Flush on EVERY node first, then read on every node, with a settling window
    # between. Flushing and reading one node at a time reported a staircase
    # (10,000 / 20,000 / 30,000 / 40,000) and called it `converged: false`, and
    # every one of those readings was correct at the instant it was taken: each
    # node rebases on the database total its OWN flush just produced, and the
    # nodes that had already flushed were never read again. The measurement was
    # wrong, not the software.
    flushes = Enum.map(nodes, &:erpc.call(&1, __MODULE__, :flush_node, [], 60_000))
    Process.sleep(ctx.converge_ms)

    reads =
      Enum.map(
        nodes,
        &:erpc.call(&1, __MODULE__, :read_node, [tenant, Modes.feature(), @period], 60_000)
      )

    Enum.each(peers, &stop_peer/1)
    _ = flushes

    admitted = Enum.sum(Enum.map(results, & &1.admitted))
    denied = Enum.sum(Enum.map(results, & &1.denied))
    finish(ctx, nodes, results, reads, admitted, denied, us, probe)
  end

  defp probe_node(node, tenant) do
    :erpc.call(node, __MODULE__, :reserve_loop, [tenant, Modes.feature(), @period, 1], 60_000)
  end

  defp run_everywhere(nodes, tenant, per_node) do
    nodes
    |> Task.async_stream(
      fn n ->
        :erpc.call(
          n,
          __MODULE__,
          :reserve_loop,
          [tenant, Modes.feature(), @period, per_node],
          300_000
        )
      end,
      max_concurrency: length(nodes),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp finish(ctx, nodes, results, reads, admitted, denied, us, probe) do
    operations = admitted + denied
    overshoot = max(admitted - ctx.cluster_limit, 0)
    bound = bound(length(nodes), operations, us)
    after_convergence = Enum.sum(Enum.map(probe, & &1.admitted))
    persisted = persisted(ctx)

    verdict =
      merge([
        compare(
          "persisted total after a flush on every node",
          persisted,
          admitted + after_convergence
        ),
        {overshoot <= bound, ["overshoot #{overshoot} against the computed bound #{bound}"]},
        compare("admitted plus denied", operations, length(nodes) * ctx.per),
        compare("admitted after one settling window", after_convergence, 0)
      ])

    %{
      operations: operations,
      duration_ms: us / 1_000,
      samples: [],
      sampled: false,
      sample_every: nil,
      errors: %{total: denied, by_tag: %{"limit_exceeded" => denied}},
      timeline: [],
      cluster_verdict: verdict,
      cluster: %{
        "nodes" => Enum.map(nodes, &to_string/1),
        "reservations_per_node" => ctx.per,
        "admitted" => admitted,
        "denied" => denied,
        "limit" => ctx.cluster_limit,
        "overshoot" => overshoot,
        "overshoot_bound" => bound,
        "bound_formula" =>
          "(nodes - 1) x ceil(per_node_reservation_rate x broadcast_interval_ms / 1000), from " <>
            "architecture-map.md section 3: the overshoot is what the other nodes admitted " <>
            "within one broadcast_interval, and inside that window a node admits everything " <>
            "it attempts",
        "per_node_reservation_rate" =>
          Stats.round2(operations / length(nodes) / (us / 1_000_000)),
        "broadcast_interval_ms" => AuroraMeter.Config.broadcast_interval(),
        "flush_interval_ms" => AuroraMeter.Config.flush_interval(),
        "per_node" => Enum.zip(Enum.map(nodes, &to_string/1), results) |> Map.new(),
        "node_values_after_flush" =>
          nodes |> Enum.map(&to_string/1) |> Enum.zip(reads) |> Map.new(),
        "persisted_total" => persisted,
        "admitted_after_one_settling_window" => after_convergence,
        "settling_window_ms" => ctx.converge_ms,
        "run_spans_broadcast_intervals" => spans(us),
        "converged" => length(Enum.uniq(reads)) == 1
      },
      notes: [
        "cluster_#{length(nodes)} ran on #{length(nodes)} real BEAM nodes started with :peer, " <>
          "each with its own supervision tree and connection pool against one database and " <>
          "one distributed PubSub. This is not a simulation.",
        spans_note(us)
      ]
    }
  end

  defp spans(us), do: Float.round(us / 1_000 / max(AuroraMeter.Config.broadcast_interval(), 1), 3)

  # The most important sentence in this record, and it is about the shape of the
  # run rather than about the software: an overshoot measured over a burst
  # shorter than one broadcast interval is the WORST case the guarantee allows,
  # because no gossip tick happened at all and every node admitted the whole
  # limit on its own. A reader who did not know that would take the number for a
  # steady-state one.
  defp spans_note(us) do
    if spans(us) < 1 do
      "the whole burst finished in #{Float.round(spans(us) * 100, 1)} percent of one " <>
        "broadcast_interval, so NO gossip tick occurred during it and every node admitted up " <>
        "to the hard limit independently. That is the worst case the guarantee allows and not " <>
        "a steady-state figure; admitted_after_one_settling_window is what shows convergence."
    else
      "the burst spanned #{spans(us)} broadcast intervals, so gossip ticked during it and the " <>
        "overshoot is what the other nodes admitted inside those windows."
    end
  end

  # The guarantee names the interval, so the bound is computed from it: what the
  # other nodes admitted within one `broadcast_interval` (architecture-map.md
  # section 3).
  #
  # The rate is the per-node **reservation** rate and not the per-node admitted
  # rate, and the difference is the whole content of the bound. Inside the
  # window before gossip arrives a node admits everything it attempts, so the
  # number it can admit in that window is its attempt rate times the interval.
  # Using the admitted rate instead divides by the whole run, most of which is a
  # long tail of denials, and produces a bound far below what the window allows.
  #
  # The first version did exactly that, and at the default interval it PASSED:
  # the burst finished inside one interval, the overshoot was the limit itself,
  # and 10,000 is comfortably under a bound of 53,556 however it is computed. It
  # took a run with a 25 ms interval, where gossip actually ticks, to show the
  # bound refusing an overshoot the guarantee allows (776 against 715). An
  # assertion that only ever runs in the shape where it cannot fail is not an
  # assertion (open-findings.md X125, X211).
  defp bound(node_count, operations, us) do
    seconds = max(us / 1_000_000, 0.000001)
    per_node_rate = operations / node_count / seconds
    interval_s = AuroraMeter.Config.broadcast_interval() / 1_000
    max((node_count - 1) * ceil(per_node_rate * interval_s), node_count - 1)
  end

  defp persisted(ctx) do
    %{rows: [[value]]} =
      ctx.repo.query!(
        "SELECT coalesce(sum(value), 0) FROM aurora_meter_counters WHERE tenant_key LIKE $1",
        [Modes.prefix(ctx) <> "%"]
      )

    Mode.to_integer(value)
  end

  defp stop_peer({pid, _node}) do
    :peer.stop(pid)
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # The one exit path that is allowed to be a non-result, and it is still a
  # complete record: `correct: false`, the reason named, and the task exits
  # non-zero so nothing downstream can treat it as a measurement.
  @doc false
  @spec unavailable(term()) :: map()
  def unavailable(reason) do
    %{
      operations: 0,
      duration_ms: 0.0,
      samples: [],
      sampled: false,
      sample_every: nil,
      errors: %{total: 1, by_tag: %{"distribution_unavailable" => 1}},
      timeline: [],
      cluster_verdict: {false, ["distribution_unavailable: #{inspect(reason)}"]},
      cluster: %{"reason" => "distribution_unavailable", "detail" => inspect(reason)},
      notes: [
        "distribution_unavailable: this mode needs real peer nodes and could not start them " <>
          "(#{inspect(reason)}). It did NOT fall back to cluster_2_sim, which is a single VM " <>
          "simulation and is not a cluster measurement."
      ]
    }
  end

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
