defmodule AuroraMeterExampleAi.SampleFixtures do
  @moduledoc """
  Organisations, users and scopes for the sample's own tests, plus the tenant
  probe the isolation tests use.
  """

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Accounts
  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.AccountsFixtures
  alias AuroraMeterExampleAi.Orgs
  alias AuroraMeterExampleAi.Repo

  @doc """
  An organisation, on the lot engine, with no credit.

  The lot engine is switched on before anything is granted, for the reason
  `mix sample.seed` explains at length: a new wallet is on the legacy engine
  otherwise, and on the legacy engine there are no lots, no allocation trail,
  and `debt` and `expired` are permanently zero.
  """
  def org_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{
        name: Map.get(attrs, :name, "Org #{n}"),
        slug: Map.get(attrs, :slug, "org-#{n}")
      })

    AuroraMeter.Credits.Ledger.enable_lots!(AuroraMeterExampleAi.Tenancy.to_key(org))
    AuroraMeter.subscribe(org, Map.get(attrs, :plan, :studio))

    org
  end

  @doc "A confirmed user in `org`, with a role."
  def user_fixture_in(org, role \\ "owner") do
    user = AccountsFixtures.user_fixture()

    user
    |> Accounts.User.org_changeset(%{org_id: org.id, role: role})
    |> Repo.update!()
  end

  @doc "A scope: a user, their organisation, and nothing else."
  def scope_fixture(org, role \\ "owner") do
    org |> user_fixture_in(role) |> Scope.for_user()
  end

  @doc """
  An organisation with a user, a plan and a funded wallet, ready to generate.

  `:credit` defaults to five dollars, which is enough for a few hundred of this
  sample's generations and nowhere near the low-balance threshold.
  """
  def funded_scope_fixture(attrs \\ %{}) do
    org = org_fixture(attrs)
    scope = scope_fixture(org, Map.get(attrs, :role, "owner"))

    case Map.get(attrs, :credit, 5_000_000) do
      0 ->
        :ok

      amount ->
        {:ok, _} = Credits.grant(org, amount, reference: grant_reference(), category: :paid)
    end

    scope
  end

  @doc "A globally unique grant reference. `(kind, reference)` is unique across every tenant."
  def grant_reference(prefix \\ "test"), do: "#{prefix}:#{System.unique_integer([:positive])}"

  @doc """
  Records every tenant key `AuroraMeterExampleAi.Tenancy.to_key/1` resolves
  while `fun` runs, and returns `{result, keys}`.

  This is what turns "the other organisation's data was never read" from a
  claim about a rendered page into a claim about the run. A page that happens
  not to show a figure proves nothing; a run in which the other organisation's
  key was never resolved cannot have read it.
  """
  def with_tenant_probe(fun) when is_function(fun, 0) do
    parent = self()
    id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      id,
      [:aurora_meter_example_ai, :tenant, :resolved],
      fn _event, _measure, %{tenant_key: key}, _config -> send(parent, {:tenant_probe, key}) end,
      nil
    )

    try do
      result = fun.()
      # Let anything the call spawned finish before the mailbox is drained.
      Process.sleep(10)
      {result, drain_probe([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_probe(acc) do
    receive do
      {:tenant_probe, key} -> drain_probe([key | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
