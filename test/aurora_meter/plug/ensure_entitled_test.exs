# Compiled only when `Plug.Test` is, exactly like the module under test
# (`lib/aurora_meter/plug/ensure_entitled.ex` opens with
# `if Code.ensure_loaded?(Plug.Conn) do`). On the `headless` leg there is no
# `plug` and therefore no plug to test; the absence is asserted positively by
# `AuroraMeter.HeadlessTest`, so a guard that swallowed this file would be
# caught rather than read as green.
if Code.ensure_loaded?(Plug.Test) do
  defmodule AuroraMeter.Plug.EnsureEntitledTest do
    @moduledoc """
    Invariant I20, build unit 09a: `AuroraMeter.Plug.EnsureEntitled` is optional,
    tenant-safe and **advisory**.

    The advisory half is the point of the file, and it is asserted as an absence:
    every row of the matrix records the feature's usage value before the request
    and after it, and every row requires them equal. The plug that this unit
    refused to ship (one that reserved at the router) would fail every one of
    them, which is invariants I03 and I04 protected negatively.

    `async: false`: most of these mutate `:plans`, `:storage`,
    `:undeclared_feature_policy` or `:period_source` through
    `AuroraMeter.Test.Config`.
    """
    use AuroraMeter.DataCase, async: false

    import AuroraMeter.Test.Config, only: [with_config: 2]
    import ExUnit.CaptureLog, only: [with_log: 1]
    import Plug.Test, only: [conn: 2]

    alias AuroraMeter.Period.InvalidPeriodError
    alias AuroraMeter.Plug.EnsureEntitled
    alias AuroraMeter.Storage.Ecto, as: EctoStorage
    alias AuroraMeter.Test.FailingSeedStorage
    alias AuroraMeter.Test.PeriodSources
    alias AuroraMeter.UndeclaredFeatureError

    # The tenant resolvers a host would write. `tenant_from_assign/1` is the only
    # shape this file uses for a present tenant, and it reads an assign the test
    # put there, never a param: a tenant read from `conn.params` is the IDOR
    # phase 08 shipped, and an example is a place people copy from.
    def tenant_from_assign(conn), do: conn.assigns[:current_org]
    def no_tenant(_conn), do: nil

    def denied_json(conn, reason) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(402, ~s({"error":"#{reason}"}))
      |> Plug.Conn.halt()
    end

    def forgets_to_halt(conn, _reason), do: conn

    def returns_rubbish(_conn, _reason), do: :nope

    describe "a missing tenant" do
      test "I20 a resolver returning nil halts with 401 and :missing_tenant" do
        conn = call_plug(nil, feature: :ai_generations, tenant: {__MODULE__, :no_tenant})

        assert conn.status == 401
        assert conn.halted
        assert conn.private[:aurora_meter_denial] == :missing_tenant
        refute Map.has_key?(conn.assigns, :aurora_meter_tenant)
        refute Map.has_key?(conn.assigns, :aurora_meter_quota)
      end

      test "I20 a resolver returning nil never resolves the default tenant" do
        # The failure this guards is not "the request was allowed", it is "the
        # request was answered against the empty-string tenant". In the 0.5.x
        # transition mode AuroraMeter.Tenant.to_key/1 lets "" through with a
        # warning (open-findings.md C12), so nothing downstream would have
        # objected. Assert the absence rather than assume it.
        #
        # Deliberately NOT asserted with AuroraMeter.usage("", :ai_generations):
        # that call seeds the very row this test is about, so it would create the
        # evidence it was written to look for.
        #
        # The two ETS assertions are DELTAS, not absolute absences, and that is
        # the fix for a third intermittent failure this unit shipped.
        # `:aurora_meter_counters` and `:aurora_meter_subscription_cache` are
        # node-wide tables shared by the whole run, and several other modules
        # legitimately resolve the empty tenant (it is what `Tenant.Default`
        # returns for anything unresolvable, and the transition-mode behaviour
        # they test). Whether a row for "" exists when this test starts is
        # therefore a question about the seed. Measured: a full run at seed
        # 638544 failed here on `refute :ets.member(...)` because an earlier
        # module had warmed that key.
        #
        # What this test is entitled to claim is that THIS REQUEST wrote nothing
        # for "", and a before/after comparison says exactly that. It is
        # deterministic because this module is `async: false`, so no other test
        # runs between the two reads. The database reads below need no such care:
        # they are inside the sandbox.
        counters_before = rows_for("")
        cached_before = :ets.lookup(:aurora_meter_subscription_cache, "")

        conn = call_plug(nil, feature: :ai_generations, tenant: {__MODULE__, :no_tenant})

        assert conn.status == 401
        assert rows_for("") == counters_before
        assert :ets.lookup(:aurora_meter_subscription_cache, "") == cached_before
        assert EctoStorage.load_counter("", :ai_generations, period_start()) == nil
        assert EctoStorage.get_subscription("") == nil
      end
    end

    describe "a denial" do
      test "I20 a denied boolean feature halts with 403 and :not_entitled" do
        tenant = subscribed(:free)

        conn = call_plug(tenant, feature: :api_access, tenant: {__MODULE__, :tenant_from_assign})

        assert conn.status == 403
        assert conn.halted
        assert conn.private[:aurora_meter_denial] == :not_entitled
        assert conn.resp_body == ""
      end

      test "I20 a hard limit at the cap halts with 403 and :limit_exceeded" do
        tenant = subscribed(:free)
        :ok = AuroraMeter.track(tenant, :ai_generations, 50)

        conn =
          call_plug(tenant, feature: :ai_generations, tenant: {__MODULE__, :tenant_from_assign})

        assert conn.status == 403
        assert conn.private[:aurora_meter_denial] == :limit_exceeded
      end

      test "I20 on_denied {module, function} receives the conn and the reason atom" do
        tenant = subscribed(:free)

        conn =
          call_plug(tenant,
            feature: :api_access,
            tenant: {__MODULE__, :tenant_from_assign},
            on_denied: {__MODULE__, :denied_json}
          )

        assert conn.status == 402
        assert conn.halted
        assert conn.resp_body == ~s({"error":"not_entitled"})
        assert conn.private[:aurora_meter_denial] == :not_entitled
      end

      test "I20 an on_denied callback that does not halt raises a RuntimeError naming the callback" do
        tenant = subscribed(:free)

        assert_raise RuntimeError,
                     ~r/AuroraMeter\.Plug\.EnsureEntitledTest\.forgets_to_halt\/2/,
                     fn ->
                       call_plug(tenant,
                         feature: :api_access,
                         tenant: {__MODULE__, :tenant_from_assign},
                         on_denied: {__MODULE__, :forgets_to_halt}
                       )
                     end
      end

      test "I20 an on_denied callback returning a non-conn raises a RuntimeError naming the callback" do
        tenant = subscribed(:free)

        assert_raise RuntimeError, ~r/returns_rubbish\/2.*:nope/s, fn ->
          call_plug(tenant,
            feature: :api_access,
            tenant: {__MODULE__, :tenant_from_assign},
            on_denied: {__MODULE__, :returns_rubbish}
          )
        end
      end
    end

    describe "a passing request" do
      test "I20 an allowed request assigns :aurora_meter_quota equal to AuroraMeter.quota/2" do
        tenant = subscribed(:pro)
        :ok = AuroraMeter.track(tenant, :ai_generations, 7)

        conn =
          call_plug(tenant, feature: :ai_generations, tenant: {__MODULE__, :tenant_from_assign})

        refute conn.halted
        assert conn.status == nil
        assert conn.assigns.aurora_meter_quota == AuroraMeter.quota(tenant, :ai_generations)
      end

      test "I20 an allowed request assigns :aurora_meter_tenant with the term the resolver returned" do
        # The TERM, not the key: a host that meters something other than a binary
        # gets its own term back and does not have to resolve it a second time.
        # An integer, because AuroraMeter.Tenant.Default stringifies anything with
        # String.Chars and the suite's configured tenant module is the default.
        term = System.unique_integer([:positive])
        {:ok, _subscription} = AuroraMeter.subscribe(term, :pro)

        conn = call_plug(term, feature: :api_access, tenant: {__MODULE__, :tenant_from_assign})

        refute conn.halted
        assert conn.assigns.aurora_meter_tenant == term
        assert is_integer(conn.assigns.aurora_meter_tenant)
      end

      test "I20 a tenant term the host's AuroraMeter.Tenant module refuses propagates, not 503" do
        # AuroraMeter.Tenant.Default has no clause for a tuple, so to_key/1 raises
        # Protocol.UndefinedError. That is a host configuration fault (meter a
        # struct, configure a tenant module), and a 503 would send an operator to
        # look at a database that is perfectly well. Found by this file: the term
        # above was a tuple on the first run and the plug answered 503.
        assert_raise Protocol.UndefinedError, fn ->
          call_plug({:org, "org_1"},
            feature: :api_access,
            tenant: {__MODULE__, :tenant_from_assign}
          )
        end
      end

      test "I20 assign_quota: false skips the quota read and still assigns the tenant" do
        tenant = subscribed(:pro)

        conn =
          call_plug(tenant,
            feature: :ai_generations,
            tenant: {__MODULE__, :tenant_from_assign},
            assign_quota: false
          )

        refute conn.halted
        assert conn.assigns.aurora_meter_tenant == tenant
        refute Map.has_key?(conn.assigns, :aurora_meter_quota)
      end
    end

    describe "the plug never reserves" do
      test "I20 usage is unchanged after a passing request" do
        tenant = subscribed(:pro)
        :ok = AuroraMeter.track(tenant, :ai_generations, 3)
        before = AuroraMeter.usage(tenant, :ai_generations)

        conn =
          call_plug(tenant, feature: :ai_generations, tenant: {__MODULE__, :tenant_from_assign})

        refute conn.halted
        assert AuroraMeter.usage(tenant, :ai_generations) == before
        assert before == 3
      end

      test "I20 twelve passing requests at the cap boundary leave usage at its starting value" do
        # One below the :free cap, so every request passes and a plug that
        # reserved a single unit would deny the second and bill eleven.
        tenant = subscribed(:free)
        :ok = AuroraMeter.track(tenant, :ai_generations, 49)
        before = AuroraMeter.usage(tenant, :ai_generations)

        opts =
          EnsureEntitled.init(feature: :ai_generations, tenant: {__MODULE__, :tenant_from_assign})

        statuses =
          for _ <- 1..12 do
            conn(:get, "/")
            |> Plug.Conn.assign(:current_org, tenant)
            |> EnsureEntitled.call(opts)
            |> Map.get(:status)
          end

        assert statuses == List.duplicate(nil, 12)
        assert AuroraMeter.usage(tenant, :ai_generations) == before
        assert before == 49
      end
    end

    describe "the undeclared-feature policy" do
      test "I20 an undeclared feature under :deny halts with 403 and :not_entitled" do
        in_policy(:deny, fn ->
          tenant = policy_tenant()

          conn = call_plug(tenant, feature: :nowhere, tenant: {__MODULE__, :tenant_from_assign})

          assert conn.status == 403
          assert conn.private[:aurora_meter_denial] == :not_entitled
        end)
      end

      test "I20 an undeclared feature under :allow passes and assigns a quota with kind :undeclared" do
        in_policy(:allow, fn ->
          tenant = policy_tenant()

          conn = call_plug(tenant, feature: :nowhere, tenant: {__MODULE__, :tenant_from_assign})

          refute conn.halted
          assert conn.assigns.aurora_meter_quota.kind == :undeclared
          assert conn.assigns.aurora_meter_quota.enabled == true
        end)
      end

      test "I20 an undeclared feature under :raise re-raises UndeclaredFeatureError rather than answering 503" do
        in_policy(:raise, fn ->
          tenant = policy_tenant()

          assert_raise UndeclaredFeatureError, fn ->
            call_plug(tenant, feature: :nowhere, tenant: {__MODULE__, :tenant_from_assign})
          end
        end)
      end
    end

    describe "modes" do
      test "I20 mode :entitled? passes at the hard cap because it never reads usage" do
        tenant = subscribed(:pro)
        :ok = AuroraMeter.track(tenant, :ai_generations, 1_000)

        conn =
          call_plug(tenant,
            feature: :ai_generations,
            tenant: {__MODULE__, :tenant_from_assign},
            mode: :entitled?,
            assign_quota: false
          )

        refute conn.halted
        assert AuroraMeter.check(tenant, :ai_generations) == {:error, :limit_exceeded}
      end

      test "I20 mode :entitled? reads no counter, and the same arming makes :check answer 503" do
        # The pair, and the pair is the assertion. "load_counter/3 was not called"
        # is worth nothing on its own: it is also what a plug that never ran
        # produces. The control arms the identical storage and runs the identical
        # request in `:check` mode, which must reach the adapter and fail.
        with_storage(fn ->
          entitled_tenant = subscribed(:pro)
          check_tenant = subscribed(:pro)

          FailingSeedStorage.arm()

          entitled =
            call_plug(entitled_tenant,
              feature: :ai_generations,
              tenant: {__MODULE__, :tenant_from_assign},
              mode: :entitled?,
              assign_quota: false
            )

          refute entitled.halted
          assert FailingSeedStorage.calls() == 0

          {control, log} =
            with_log(fn ->
              call_plug(check_tenant,
                feature: :ai_generations,
                tenant: {__MODULE__, :tenant_from_assign}
              )
            end)

          assert control.status == 503, "the control never reached the storage adapter: " <> log
          assert FailingSeedStorage.calls() >= 1
        end)
      end
    end

    describe "failures the plug classifies" do
      test "I20 a storage failure during a cold counter seed halts with 503 and :unavailable" do
        with_storage(fn ->
          tenant = subscribed(:pro)
          FailingSeedStorage.arm()

          {conn, log} =
            with_log(fn ->
              call_plug(tenant,
                feature: :ai_generations,
                tenant: {__MODULE__, :tenant_from_assign}
              )
            end)

          assert conn.status == 503
          assert conn.halted
          assert conn.private[:aurora_meter_denial] == :unavailable
          assert log =~ "AuroraMeter.Plug.EnsureEntitled could not decide :ai_generations"
          assert log =~ "DBConnection.ConnectionError"
        end)
      end

      test "I20 InvalidPeriodError from a custom period source is re-raised, not turned into 503" do
        with_config([{:aurora_meter, :period_source, PeriodSources.NotAMap}], fn ->
          tenant = unique_tenant()

          assert_raise InvalidPeriodError, fn ->
            call_plug(tenant, feature: :ai_generations, tenant: {__MODULE__, :tenant_from_assign})
          end
        end)
      end

      test "I20 a resolver that raises propagates unchanged" do
        assert_raise ArgumentError, "resolver blew up", fn ->
          conn(:get, "/")
          |> EnsureEntitled.call(
            EnsureEntitled.init(
              feature: :ai_generations,
              tenant: fn _conn -> raise ArgumentError, "resolver blew up" end
            )
          )
        end
      end
    end

    describe "init/1" do
      test "I20 init/1 raises on an unknown option" do
        assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:retry_after\]/, fn ->
          EnsureEntitled.init(
            feature: :ai_generations,
            tenant: {__MODULE__, :tenant_from_assign},
            retry_after: 30
          )
        end
      end

      test "I20 init/1 raises when :tenant is missing" do
        assert_raise NimbleOptions.ValidationError, ~r/required :tenant option not found/, fn ->
          EnsureEntitled.init(feature: :ai_generations)
        end
      end

      test "I20 init/1 raises when :feature is a binary" do
        assert_raise NimbleOptions.ValidationError, ~r/invalid value for :feature option/, fn ->
          EnsureEntitled.init(
            feature: "ai_generations",
            tenant: {__MODULE__, :tenant_from_assign}
          )
        end
      end

      test "I20 init/1 raises when :mode is not one of the two" do
        assert_raise NimbleOptions.ValidationError, ~r/invalid value for :mode option/, fn ->
          EnsureEntitled.init(
            feature: :ai_generations,
            tenant: {__MODULE__, :tenant_from_assign},
            mode: :reserve
          )
        end
      end

      test "I20 init/1 accepts a one-argument function and a {module, function} pair" do
        assert %{tenant: {__MODULE__, :tenant_from_assign}} =
                 EnsureEntitled.init(
                   feature: :ai_generations,
                   tenant: {__MODULE__, :tenant_from_assign}
                 )

        assert %{tenant: fun} =
                 EnsureEntitled.init(feature: :ai_generations, tenant: &__MODULE__.no_tenant/1)

        assert is_function(fun, 1)
      end
    end

    defp call_plug(tenant, opts) do
      conn(:get, "/")
      |> Plug.Conn.assign(:current_org, tenant)
      |> EnsureEntitled.call(EnsureEntitled.init(opts))
    end

    defp subscribed(plan) do
      tenant = unique_tenant()
      {:ok, _subscription} = AuroraMeter.subscribe(tenant, plan)
      tenant
    end

    defp policy_tenant do
      tenant = unique_tenant()
      {:ok, _subscription} = AuroraMeter.subscribe(tenant, :policy)
      tenant
    end

    defp in_policy(policy, fun) do
      with_config(
        [
          {:aurora_meter, :plans, AuroraMeter.Test.PolicyPlans},
          {:aurora_meter, :undeclared_feature_policy, policy}
        ],
        fun
      )
    end

    defp with_storage(fun) do
      on_exit(&FailingSeedStorage.disarm/0)

      with_config([{:aurora_meter, :storage, FailingSeedStorage}], fn ->
        try do
          fun.()
        after
          FailingSeedStorage.disarm()
        end
      end)
    end

    defp period_start, do: AuroraMeter.Period.current!("probe_period").start

    defp rows_for(tenant_key) do
      :ets.match_object(:aurora_meter_counters, {{tenant_key, :_, :_}, :_, :_, :_, :_, :_})
    end
  end
end
