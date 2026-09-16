defmodule AuroraMeter.PlanPreviewTest do
  @moduledoc """
  Build unit 07b, task 07.09: the dry run.

  `preview_transition/3` is the screen a customer is shown before they commit,
  so the thing worth proving is that it writes nothing and that it never invents
  a provider mapping it does not have.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.FakeProvider

  @inside_september ~U[2026-09-16 10:00:00Z]

  defp subscribed(plan) do
    tenant = unique_tenant("prev")
    {:ok, _} = AuroraMeter.subscribe(tenant, plan)
    Subscriptions.invalidate(tenant)
    tenant
  end

  defp change(preview, name) do
    Enum.find(preview.changes, &(&1.name == name))
  end

  test "I17 preview_transition returns the old and new entitlements without writing anything" do
    tenant = subscribed(:pro)
    before = {row_count("aurora_meter_subscriptions"), row_count("aurora_meter_plan_transitions")}

    {:ok, preview} = Subscriptions.preview_transition(tenant, :scale)

    assert preview.from.plan_id == :pro
    assert preview.from.version == "1"
    assert preview.to.plan_id == :scale
    assert preview.to.version == "1"

    assert {row_count("aurora_meter_subscriptions"), row_count("aurora_meter_plan_transitions")} ==
             before

    assert TestRepo.get_by(PlanTransition, tenant_key: tenant) == nil
  end

  test "I17 preview_transition reports a limit change, an added feature and a removed feature" do
    tenant = subscribed(:free)
    {:ok, preview} = Subscriptions.preview_transition(tenant, :pro)

    assert change(preview, :ai_generations) == %{
             kind: :feature,
             name: :ai_generations,
             from: {:limit, 50, :hard},
             to: {:limit, 1_000, :hard},
             direction: :increase
           }

    assert change(preview, :api_access).direction == :increase
    assert change(preview, :seats).direction == :increase

    {:ok, back} = Subscriptions.preview_transition(subscribed(:pro), :free)
    assert change(back, :ai_generations).direction == :decrease
    assert change(back, :api_access).direction == :decrease
  end

  test "I17 preview_transition reports an added and a removed feature by name" do
    # `:pro` declares `:ai_generations` as a hard limit and `:payg` declares
    # `:requests` as a counter, so one feature is added and one removed.
    tenant = subscribed(:pro)
    {:ok, preview} = Subscriptions.preview_transition(tenant, :payg)

    assert change(preview, :requests).direction == :added
    assert change(preview, :requests).from == nil
    assert change(preview, :ai_generations).direction == :removed
    assert change(preview, :ai_generations).to == nil
  end

  test "I17 preview_transition reports recurring credit changes" do
    tenant = subscribed(:pro)
    {:ok, preview} = Subscriptions.preview_transition(tenant, :allowance)

    monthly = change(preview, :monthly)
    assert monthly.kind == :recurring_credits
    assert monthly.direction == :added
    assert monthly.to.amount == 5_000_000

    {:ok, dropped} = Subscriptions.preview_transition(subscribed(:allowance), :pro)
    assert change(dropped, :monthly).direction == :removed
  end

  test "I17 preview_transition reports an unchanged feature not at all" do
    tenant = subscribed(:pro)
    {:ok, preview} = Subscriptions.preview_transition(tenant, :scale)

    # `:api_access` is `true` on both, so it is absent from the diff entirely.
    assert change(preview, :api_access) == nil
    assert change(preview, :seats).direction == :increase
  end

  test "I17 preview_transition returns the effective time and the tenant's period" do
    tenant = subscribed(:pro)

    AuroraMeter.Test.with_clock(@inside_september, fn ->
      {:ok, preview} = Subscriptions.preview_transition(tenant, :scale)

      assert preview.effective_at == ~U[2026-10-01 00:00:00Z]
      assert preview.period.start == ~U[2026-09-01 00:00:00Z]
      assert preview.period.end == ~U[2026-10-01 00:00:00Z]
      assert preview.period.source == :calendar
    end)
  end

  test "I17 preview_transition with Billing.Noop reports provider status :not_configured" do
    tenant = subscribed(:pro)
    {:ok, preview} = Subscriptions.preview_transition(tenant, :scale)

    assert preview.provider == %{status: :not_configured, detail: %{}}
  end

  test "I17 preview_transition with a provider implementing describe_plan_change shows it" do
    tenant = subscribed(:pro)

    Config.with_config([{:aurora_meter, :provider, FakeProvider.Describing}], fn ->
      {:ok, preview} = Subscriptions.preview_transition(tenant, :scale)

      assert preview.provider.status == :ok
      assert preview.provider.detail.price_id == "price_scale_v1_month"
      assert preview.provider.detail.proration_behavior == "none"
    end)
  end

  test "I17 preview_transition with a provider that returns an error keeps the diff" do
    tenant = subscribed(:free)

    Config.with_config([{:aurora_meter, :provider, FakeProvider.Erroring}], fn ->
      {:ok, preview} = Subscriptions.preview_transition(tenant, :pro)

      assert preview.provider == %{status: :error, detail: %{reason: :no_price_for_version}}
      assert change(preview, :ai_generations).direction == :increase
    end)
  end

  test "I17 preview_transition with a provider that raises keeps the diff" do
    tenant = subscribed(:free)

    Config.with_config([{:aurora_meter, :provider, FakeProvider.Raising}], fn ->
      {:ok, preview} = Subscriptions.preview_transition(tenant, :pro)

      assert preview.provider.status == :error
      assert %RuntimeError{} = preview.provider.detail.reason
      assert change(preview, :ai_generations).direction == :increase
    end)
  end

  test "I17 preview_transition of a zero-price transition reports price 0 and no proration" do
    tenant = subscribed(:pro)
    {:ok, preview} = Subscriptions.preview_transition(tenant, :free)

    assert preview.from.price == 2_000
    assert preview.to.price == 0

    # Core computes none, so the map carries no proration key of its own: the
    # only place one can appear is inside the provider's own detail.
    refute Map.has_key?(preview, :proration)
    refute Map.has_key?(preview.to, :proration)
    assert preview.provider == %{status: :not_configured, detail: %{}}
  end

  test "I17 preview_transition of an unknown plan is refused" do
    tenant = subscribed(:pro)

    assert {:error, {:invalid, [to_plan: "is not a known plan"]}} =
             Subscriptions.preview_transition(tenant, :no_such_plan)
  end

  test "I17 preview_transition of an unknown version is refused" do
    tenant = subscribed(:pro)

    assert {:error, {:invalid, [to_plan_version: "is not a known version of this plan"]}} =
             Subscriptions.preview_transition(tenant, :scale, version: "99")
  end

  test "I17 preview_transition for a tenant with no subscription previews from the default plan" do
    tenant = unique_tenant("prev")
    {:ok, preview} = Subscriptions.preview_transition(tenant, :scale)

    assert preview.from.plan_id == AuroraMeter.plan(tenant).id
    assert preview.to.plan_id == :scale
  end

  defp row_count(table) do
    %{rows: [[count]]} = TestRepo.query!("SELECT count(*) FROM #{table}", [])
    count
  end
end
