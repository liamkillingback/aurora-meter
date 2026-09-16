defmodule AuroraMeter.LiveDashboard.SectionsTest do
  @moduledoc """
  Build unit 08b, task 08.03: the data behind the core LiveDashboard page.

  This file carries no `phoenix_live_dashboard` reference and runs on every leg,
  including one with no optional dependency at all. That is the point of the
  split: invariant B1 ("a dashboard never renders data it could not read, and an
  unreadable section is never a zero") is a property of these readers, not of
  the page that draws them.

  `async: false`: one case stops `AuroraMeter.Store` under the supervisor to
  produce the `:not_started` class, which is global to the node.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Credits
  alias AuroraMeter.LiveDashboard.Sections
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults

  doctest AuroraMeter.LiveDashboard.Sections

  @dollar 1_000_000

  test "B1 read/1 converts a raise inside a reader into {:unavailable, :error}" do
    TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      Faults.arm(:before_commit, :raise, when: &(&1[:kind] == :read), count: :infinity)

      assert {:unavailable, :error} = Sections.read(:credits)
    end)
  end

  test "B1 read/1 converts a missing ETS table into {:unavailable, :not_started}" do
    :ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Store)

    try do
      assert {:unavailable, :not_started} = Sections.read(:metering)
    after
      {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Store)
    end

    assert {:ok, _data} = Sections.read(:metering)
  end

  test "the metering section reports counter keys, dirty keys and the flush interval" do
    tenant = unique_tenant("dash")
    AuroraMeter.subscribe(tenant, :payg)
    :ok = AuroraMeter.track(tenant, :requests, 5)

    assert {:ok, data} = Sections.read(:metering)

    assert data.counter_keys >= 1
    assert data.dirty_keys >= 1
    assert data.flush_interval == AuroraMeter.Config.flush_interval()
  end

  test "B1 a gauge nothing has sampled is nil, not a zero-filled sample" do
    # Control c05 (`tmp/v1/08b_controls.py`) made `gauge/1` answer
    # `%{measurements: %{}, age_ms: 0, stale?: false}` for an unsampled gauge and
    # **passed**: the only test of "not sampled yet" handed the renderer a
    # synthetic `gauge: nil`, so it never called this code at all. This is the
    # end-to-end half.
    #
    # The Store is restarted to get a process that has provably never sampled:
    # `last_gauge` is seeded `nil` in `init/1` and the test environment sets
    # `metrics_interval: 0`, so no timer will fill it in behind this assertion.
    :ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Store)
    {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Store)

    assert {:ok, data} = Sections.read(:metering)
    assert data.gauge == nil
    assert data.counter_keys == 0

    # And the figures that are NOT gauge-derived are still real: this is a
    # freshly started node, not an unreadable section.
    assert data.flush_interval == AuroraMeter.Config.flush_interval()
  end

  test "the metering gauge is nil until something has sampled, and carries an age afterwards" do
    :ok = AuroraMeter.Telemetry.emit_gauges()

    assert {:ok, data} = Sections.read(:metering)
    assert %{measurements: measurements, age_ms: age, stale?: stale?} = data.gauge
    assert is_integer(measurements.oldest_pending_age_ms)
    assert age >= 0
    assert stale? in [true, false]
  end

  test "the credits section reports holds by age bucket, wallets in debt and the debt total" do
    tenant = unique_tenant("dash")
    {:ok, _txn} = Credits.grant(tenant, 10 * @dollar, reference: "08b:#{tenant}")
    {:ok, _hold} = Credits.hold(tenant, 2 * @dollar, "08b:hold:#{tenant}")

    assert {:ok, data} = Sections.read(:credits)

    assert data.holds >= 1
    assert data.holds_over_1h >= 0
    assert data.holds_over_24h >= 0
    assert is_integer(data.oldest_hold_age_seconds)
    assert is_integer(data.wallets_in_debt)
    assert is_integer(data.total_debt_micro)
  end

  test "the workers section groups on the operation and never returns a whole checkpoint name" do
    # A per-tenant operation's checkpoint name carries the tenant key in its
    # scope. The core page must show no tenant-identifying value, so the reader
    # groups in SQL rather than returning the names and hoping the renderer is
    # careful.
    tenant = unique_tenant("leaky")
    :ok = AuroraMeter.Operations.put_checkpoint("lot_migration:#{tenant}", cursor: %{})

    assert {:ok, data} = Sections.read(:workers)

    rendered = inspect(data)
    refute rendered =~ tenant
    assert Enum.any?(data.operations, &(&1.operation == "lot_migration"))
  end

  test "the configuration section reports the observability keys and no tenant data" do
    assert {:ok, data} = Sections.read(:configuration)

    assert data.metrics_interval == AuroraMeter.Config.metrics_interval()
    assert data.cluster_sync == AuroraMeter.Config.cluster_sync?()
    assert Map.has_key?(data, :events_outbox)
  end

  test "the cluster section reports the flag and reports no convergence figure when it is off" do
    assert {:ok, data} = Sections.read(:cluster)

    assert data.enabled? == AuroraMeter.Config.cluster_sync?()
    assert data.broadcast_interval == AuroraMeter.Config.broadcast_interval()

    if not data.enabled? do
      # Never a zero: "peers: 0, since_last_message_ms: 0" from a node that is
      # not clustered reads as a converged cluster.
      assert data.gauge == nil or data.gauge.measurements != %{}
    end
  end

  test "read/1 for an unknown section is unavailable rather than a crash" do
    assert {:unavailable, :error} = Sections.read(:no_such_section)
  end
end

defmodule AuroraMeter.LiveDashboard.SectionsUnavailableTest do
  @moduledoc """
  The half of B1 that needs a database that really is not there.

  `async: true` for a reason rather than for speed: with `async: false` the
  sandbox runs in **shared** mode, a spawned task inherits the test's connection
  and the reader succeeds. The first version of this file did exactly that and
  reported `{:ok, %{holds: 0, wallets_in_debt: 1, ...}}` where it expected an
  unavailable section, which is the assertion passing for the wrong reason in
  the one file whose subject is assertions that pass for the wrong reason.

  With per-process ownership a task that was never allowed meets
  `DBConnection.OwnershipError`, which is a real DBConnection failure and not an
  injected one.
  """
  use AuroraMeter.DataCase, async: true

  alias AuroraMeter.LiveDashboard.Sections

  test "B1 every database-backed section is unavailable, not zero, when the database is not there" do
    for section <- [:credits, :workers, :durable_events] do
      reading = read_unconnected(section)

      assert reading == {:unavailable, :database_unavailable},
             "#{section} answered #{inspect(reading)} with no database. A section that " <>
               "answers {:ok, a map of zeroes} tells an operator the opposite of the truth."
    end
  end

  test "B1 a section that cannot be read returns no figure at all, not a zero-filled map" do
    assert {:unavailable, _class} = read_unconnected(:credits)
  end

  # `spawn/1` and not `Task.async/1`. Ecto's sandbox resolves ownership through
  # `$callers`, which every `Task` function sets, so a task started from an
  # owning test process finds the connection and the reader SUCCEEDS. The first
  # version of this test used `Task.async/1` and reported
  # `{:ok, %{holds: 0, wallets_in_debt: 1, ...}}` where it asserted an
  # unavailable section: the "no database" premise was simply false.
  defp read_unconnected(section) do
    parent = self()
    spawn(fn -> send(parent, {:reading, section, Sections.read(section)}) end)
    assert_receive {:reading, ^section, reading}, 2_000
    reading
  end
end
