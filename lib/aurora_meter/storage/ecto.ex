defmodule AuroraMeter.Storage.Ecto do
  @moduledoc """
  Default `AuroraMeter.Storage` adapter, backed by the host's Ecto repo
  (`AuroraMeter.Config.repo/0`). Counter and event writes use `insert_all` for
  throughput; counter upserts replace absolute values so flushes are idempotent.
  """

  @behaviour AuroraMeter.Storage

  import Ecto.Query

  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Schema.Subscription

  @impl AuroraMeter.Storage
  def upsert_counters(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          period_start: row.period_start,
          value: row.value,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all(Counter, entries,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:tenant_key, :feature, :period_start]
    )

    :ok
  end

  @impl AuroraMeter.Storage
  def load_counter(tenant_key, feature, period_start) do
    feature = to_string(feature)

    repo().one(
      from(c in Counter,
        where:
          c.tenant_key == ^tenant_key and c.feature == ^feature and
            c.period_start == ^period_start,
        select: c.value
      )
    )
  end

  @impl AuroraMeter.Storage
  def upsert_history(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          bucket_kind: "day",
          bucket_start: row.date,
          value: row.value,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all(History, entries,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:tenant_key, :feature, :bucket_kind, :bucket_start]
    )

    :ok
  end

  @impl AuroraMeter.Storage
  def load_history(tenant_key, feature, date) do
    feature = to_string(feature)

    repo().one(
      from(h in History,
        where:
          h.tenant_key == ^tenant_key and h.feature == ^feature and h.bucket_kind == "day" and
            h.bucket_start == ^date,
        select: h.value
      )
    )
  end

  @impl AuroraMeter.Storage
  def load_history_range(tenant_key, feature, from, to) do
    feature = to_string(feature)

    repo().all(
      from(h in History,
        where:
          h.tenant_key == ^tenant_key and h.feature == ^feature and h.bucket_kind == "day" and
            h.bucket_start >= ^from and h.bucket_start <= ^to,
        order_by: [asc: h.bucket_start],
        select: %{date: h.bucket_start, value: h.value}
      )
    )
  end

  @impl AuroraMeter.Storage
  def get_subscription(tenant_key), do: repo().get_by(Subscription, tenant_key: tenant_key)

  @impl AuroraMeter.Storage
  def put_subscription(attrs) do
    %Subscription{}
    |> Subscription.changeset(Map.new(attrs))
    |> repo().insert(
      on_conflict: {:replace_all_except, [:id, :tenant_key, :inserted_at]},
      conflict_target: [:tenant_key],
      returning: true
    )
  end

  @impl AuroraMeter.Storage
  def insert_events(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          quantity: Map.get(row, :quantity, 1),
          metadata: Map.get(row, :metadata, %{}),
          inserted_at: now
        }
      end)

    repo().insert_all(Event, entries)
    :ok
  end

  @impl AuroraMeter.Storage
  def stream_counters(period_start) do
    repo().all(from(c in Counter, where: c.period_start == ^period_start))
  end

  @spec repo() :: module()
  defp repo, do: AuroraMeter.Config.repo()
end
