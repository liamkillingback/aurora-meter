defmodule AuroraMeter.Telemetry do
  @moduledoc """
  The telemetry contract: the event catalogue as data, the tag rules, the
  redaction helper and the on-demand gauges.

  Aurora Meter emits `:telemetry` events and nothing else. It starts no
  exporter, opens no socket and sends nothing anywhere: what a host does with
  these events is entirely the host's decision. `AuroraMeter.Telemetry.Metrics`
  offers `Telemetry.Metrics` presets for hosts that want a reporter, and it is
  compiled only when that optional dependency is present.

  ## Why the catalogue is data

  `events/0` returns one entry per event, with its real measurement and
  metadata keys and the closed set of metadata keys that are safe to use as a
  **metric tag**. Documentation drifts from code when the only thing joining
  them is a person reading both; `AuroraMeter.TelemetryContractTest` compares
  this catalogue against the emit sites in `lib/`, against `docs/api.md` and
  against `docs/telemetry.md`, in both directions, so a new event that is not
  documented and a documented event that is not emitted both fail the suite.

  ## Cardinality is the reason for the tag rules

  A metric tagged on `tenant_key` creates one time series per tenant, and one
  tagged on any `_id` creates one per object. Both are unbounded, and the cost
  lands on the host's monitoring bill and on its reporter's memory rather than
  here, which is exactly why the library must not teach it by example.

  `tag_allow_list/0` is closed. Every tag a preset uses is one of those names,
  and the value set behind each is bounded by something nameable in the source:

  | Tag | Bounded by |
  |---|---|
  | `:result` | the documented outcome set of the operation that emits it |
  | `:kind` | `AuroraMeter.Schema.CreditTransaction.kinds/0`, the retention table allow list, the cluster batch kinds, the span exception kinds |
  | `:state` | the state machine that owns the event |
  | `:exporter` | the exporter modules a host configures |
  | `:worker` | the `AuroraMeter.Oban.*` module list |
  | `:feature` | the host's compiled plan definitions, which is why it is **opt-in** |

  `forbidden_tags/0` and `forbidden_tag_suffixes/0` are the other half: names
  that must never become a tag, whatever a preset believes about them.

  The library polices its own presets and can do nothing about a handler a host
  writes. That is a real limit and it is stated plainly rather than implied
  away: attach whatever you like, but `redact/2` is here so you do not have to
  invent the rule yourself.

  ## Gauges

  Three measurements have no natural event because nothing happens when they
  change: how much is buffered, how old the oldest buffered thing is, and how
  far behind the cluster is. They are sampled on a timer inside processes that
  already exist (`AuroraMeter.Store` and `AuroraMeter.Cluster`), every
  `:metrics_interval` milliseconds. Set `metrics_interval: 0` to switch the
  timers off and drive `emit_gauges/0` from `telemetry_poller` or any other
  scheduler.

  Handlers attached to a gauge run **inside the emitting process**. A slow
  handler on `[:aurora_meter, :store, :gauge]` delays flush batch snapshots; do
  no I/O in one.
  """

  alias AuroraMeter.Cluster
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Store

  @typedoc """
  One entry in the catalogue.

  `:event` is the literal name at the emit site and `:form` is how it is
  emitted. A segment computed at the emit site appears as `:"<kind>"` with
  `form: :family`, and `:names` then lists the concrete names a handler
  attaches to. A `form: :span` entry emits the `:start`, `:stop` and
  `:exception` names under `:event`, and `:names` lists all three.
  """
  @type event_doc :: %{
          event: [atom()],
          form: :execute | :span | :family,
          names: [[atom()]],
          measurements: [atom()],
          metadata: [atom()],
          tags: [atom()],
          description: String.t(),
          since: String.t(),
          emitter: module()
        }

  @tag_allow_list [:result, :kind, :exporter, :state, :worker]
  @feature_tag :feature

  # Named rather than derived: a denial list that is only "everything not on the
  # allow list" cannot say *why*, and the test that tries each one by name is
  # the test that would notice a preset quietly acquiring it.
  @forbidden_tags [
    :tenant_key,
    :tenant,
    :reference,
    :origin,
    :node,
    :error,
    :reason,
    :stacktrace,
    :dimensions,
    :metadata,
    :payload,
    :period_start,
    :customer,
    :email,
    :cursor,
    :generation,
    :name,
    :table,
    :handler,
    :decision,
    :outcome,
    :attempts,
    :watermark,
    :subject,
    :subject_ref,
    :plan_id,
    :plan_version,
    :from_plan_id,
    :to_plan_id,
    :from_version,
    :to_version,
    :ref
  ]

  @forbidden_tag_suffixes ["_key", "_id", "_secret", "_token", "_ref"]

  # `redact/2` drops these outright. Every one either identifies a customer, a
  # payment or an object, or is free-form text with no bound at all.
  @redact_drop [
    :reference,
    :ref,
    :dimensions,
    :metadata,
    :payload,
    :reason,
    :stacktrace,
    :customer,
    :email,
    :handler
  ]

  @doc """
  The closed set of metadata keys a preset may use as a metric tag.

  `:feature` is not on it. It is offered separately, behind
  `metrics_feature_label: true`, because its bound is the **host's** plan
  definitions and only the host knows how many that is.

  ## Examples

      iex> AuroraMeter.Telemetry.tag_allow_list()
      [:result, :kind, :exporter, :state, :worker]

  """
  @spec tag_allow_list() :: [atom()]
  def tag_allow_list, do: @tag_allow_list

  @doc """
  The opt-in tag, `:feature`.

  ## Examples

      iex> AuroraMeter.Telemetry.feature_tag()
      :feature

  """
  @spec feature_tag() :: atom()
  def feature_tag, do: @feature_tag

  @doc """
  Metadata keys that must never be a metric tag, named one by one.

  ## Examples

      iex> :tenant_key in AuroraMeter.Telemetry.forbidden_tags()
      true

  """
  @spec forbidden_tags() :: [atom()]
  def forbidden_tags, do: @forbidden_tags

  @doc """
  Name suffixes that must never be a metric tag, whatever the rest of the name.

  ## Examples

      iex> AuroraMeter.Telemetry.forbidden_tag_suffixes()
      ["_key", "_id", "_secret", "_token", "_ref"]

  """
  @spec forbidden_tag_suffixes() :: [String.t()]
  def forbidden_tag_suffixes, do: @forbidden_tag_suffixes

  @doc """
  Whether `tag` may be used as a metric tag.

  `feature_label?` says whether the host has turned the opt-in `:feature` tag
  on; with it `false`, `:feature` is refused like any other name.

  ## Examples

      iex> AuroraMeter.Telemetry.tag_allowed?(:result, false)
      true

      iex> AuroraMeter.Telemetry.tag_allowed?(:tenant_key, true)
      false

      iex> AuroraMeter.Telemetry.tag_allowed?(:feature, false)
      false

  """
  @spec tag_allowed?(atom(), boolean()) :: boolean()
  def tag_allowed?(tag, feature_label?) when is_atom(tag) and is_boolean(feature_label?) do
    cond do
      tag in @forbidden_tags -> false
      forbidden_suffix?(tag) -> false
      tag in @tag_allow_list -> true
      tag == @feature_tag -> feature_label?
      true -> false
    end
  end

  defp forbidden_suffix?(tag) do
    name = Atom.to_string(tag)
    Enum.any?(@forbidden_tag_suffixes, &String.ends_with?(name, &1))
  end

  @doc """
  The event catalogue.

  Every entry names measurement and metadata keys that the emitter really
  writes. `:tags` is the subset of `:metadata` a preset may tag on, before the
  opt-in `:feature` tag is added.

  ## Examples

      iex> AuroraMeter.Telemetry.events() |> Enum.find(&(&1.event == [:aurora_meter, :flush])) |> Map.get(:measurements)
      [:count, :delta_sum]

  """
  @spec events() :: [event_doc()]
  def events do
    [
      %{
        event: [:aurora_meter, :track],
        form: :execute,
        names: [[:aurora_meter, :track]],
        measurements: [:count],
        metadata: [:declared, :feature, :tenant_key],
        tags: [],
        description:
          "One buffered increment. `declared` is false when no plan declares the feature.",
        since: "0.1.0",
        emitter: AuroraMeter
      },
      %{
        event: [:aurora_meter, :reserve],
        form: :execute,
        names: [[:aurora_meter, :reserve]],
        measurements: [:qty],
        metadata: [:declared, :feature, :result, :tenant_key],
        tags: [:result],
        description:
          "One entitlement reservation. `result` is `:ok`, `:limit_exceeded` or `:not_entitled`.",
        since: "0.2.0",
        emitter: AuroraMeter.Entitlements
      },
      %{
        event: [:aurora_meter, :flush],
        form: :execute,
        names: [[:aurora_meter, :flush]],
        measurements: [:count, :delta_sum],
        metadata: [],
        tags: [],
        description: "One committed flush batch. Kept unchanged beside the span below.",
        since: "0.1.0",
        emitter: AuroraMeter.Flusher
      },
      %{
        event: [:aurora_meter, :flush, :error],
        form: :execute,
        names: [[:aurora_meter, :flush, :error]],
        measurements: [:count],
        metadata: [:error],
        tags: [],
        description:
          "The database write failed and the same batch is retained for an idempotent retry.",
        since: "0.3.0",
        emitter: AuroraMeter.Flusher
      },
      %{
        event: [:aurora_meter, :flush],
        form: :span,
        names: [
          [:aurora_meter, :flush, :start],
          [:aurora_meter, :flush, :stop],
          [:aurora_meter, :flush, :exception]
        ],
        measurements: [:count, :delta_sum, :duration, :monotonic_time, :system_time],
        metadata: [:batch_id, :counter_rows, :history_rows, :kind, :reason, :result, :stacktrace],
        tags: [:result, :kind],
        description:
          "A span around the storage write. `:stop` carries `duration` and " <>
            "`result` (`:ok` or `:error`); `:exception` carries `kind`. " <>
            "`batch_id` is metadata for correlation and never a tag.",
        since: "1.0.0",
        emitter: AuroraMeter.Flusher
      },
      %{
        event: [:aurora_meter, :broadcast],
        form: :execute,
        names: [[:aurora_meter, :broadcast]],
        measurements: [:count, :deltas],
        metadata: [],
        tags: [],
        description: "One PubSub broadcast tick of touched counters.",
        since: "0.1.0",
        emitter: AuroraMeter.Broadcaster
      },
      %{
        event: [:aurora_meter, :cluster, :apply],
        form: :execute,
        names: [[:aurora_meter, :cluster, :apply]],
        measurements: [:count],
        metadata: [:kind, :origin],
        tags: [:kind],
        description:
          "Deltas or totals applied from another node. `origin` is a node name, " <>
            "which rotates over a deployment's life: metadata only, never a tag.",
        since: "0.3.0",
        emitter: AuroraMeter.Cluster
      },
      %{
        event: [:aurora_meter, :cluster, :lag],
        form: :execute,
        names: [[:aurora_meter, :cluster, :lag]],
        measurements: [:peers, :since_last_message_ms, :unreconciled_keys],
        metadata: [:node],
        tags: [],
        description:
          "Node-local convergence state, sampled every `:metrics_interval`. " <>
            "`unreconciled_keys` is omitted, not zeroed, above the scan ceiling.",
        since: "1.0.0",
        emitter: AuroraMeter.Cluster
      },
      %{
        event: [:aurora_meter, :store, :gauge],
        form: :execute,
        names: [[:aurora_meter, :store, :gauge]],
        measurements: [
          :counter_keys,
          :dirty_keys,
          :oldest_pending_age_ms,
          :pending_batch_age_ms,
          :pending_batch_items
        ],
        metadata: [:node],
        tags: [],
        description:
          "What is buffered and how old it is, sampled every `:metrics_interval`. " <>
            "Both ages are monotonic spans measured inside one node.",
        since: "1.0.0",
        emitter: AuroraMeter.Store
      },
      %{
        event: [:aurora_meter, :credits, :"<kind>"],
        form: :family,
        names: for(kind <- CreditTransaction.kinds(), do: [:aurora_meter, :credits, kind]),
        measurements: [:amount, :available_after, :balance_after, :spendable_after],
        metadata: [:category, :deferred, :duplicate, :overrun, :reference, :tenant_key],
        tags: [],
        description:
          "One per committed ledger entry; the kind is the last segment of the " <>
            "event name, so a preset needs no tag for it. `reference` is the " <>
            "caller's idempotency key and in a Pro deployment it carries payment " <>
            "identifiers: metadata only, never a tag and never an unredacted log.",
        since: "0.4.0",
        emitter: AuroraMeter.Credits.Ledger
      },
      %{
        event: [:aurora_meter, :credits, :low_balance],
        form: :execute,
        names: [[:aurora_meter, :credits, :low_balance]],
        measurements: [:available, :spendable, :threshold],
        metadata: [:crossing_id, :handler, :tenant_key],
        tags: [],
        description: "The available balance crossed below the threshold, once per crossing.",
        since: "0.4.0",
        emitter: AuroraMeter.Credits.Ledger
      },
      %{
        event: [:aurora_meter, :credits, :hold_reconciliation],
        form: :execute,
        names: [[:aurora_meter, :credits, :hold_reconciliation]],
        measurements: [:age_seconds, :amount, :duration],
        metadata: [:decision, :outcome, :reference, :tenant_key],
        tags: [],
        description:
          "One per hold `AuroraMeter.Credits.reconcile_holds/1` examined. " <>
            "`decision` is `:keep`, `:release`, `:none` or `{:settle, amount}`: the " <>
            "tuple makes it unbounded, so the preset maps it onto `kind` and keeps " <>
            "only the tag. `outcome` maps onto `result` the same way.",
        since: "0.6.0",
        emitter: AuroraMeter.Credits.Reconciliation
      },
      %{
        event: [:aurora_meter, :credits, :conservation_error],
        form: :execute,
        names: [[:aurora_meter, :credits, :conservation_error]],
        measurements: [:balance_delta, :expired_delta, :held_delta, :promotional_delta],
        metadata: [:operation, :reference, :tenant_key],
        tags: [],
        description: "A wallet column moved by an amount the ledger cannot account for.",
        since: "0.6.0",
        emitter: AuroraMeter.Credits.Allocator
      },
      %{
        event: [:aurora_meter, :credits, :lot_migration],
        form: :execute,
        names: [[:aurora_meter, :credits, :lot_migration]],
        measurements: [:blocked, :deferred, :duration_ms, :migrated, :rows, :wallets],
        metadata: [:shadow, :state],
        tags: [:state],
        description: "One batch of the lot cutover. `shadow: true` is a dry run.",
        since: "0.6.0",
        emitter: AuroraMeter.Credits.LotMigration
      },
      %{
        event: [:aurora_meter, :credits, :recurrence],
        form: :execute,
        names: [[:aurora_meter, :credits, :recurrence]],
        measurements: [:amount, :rollover_amount],
        metadata: [:name, :period_start, :plan_id, :plan_version, :reason, :result, :tenant_key],
        tags: [:result],
        description:
          "One recurring grant period. `period_start` grows one series per period " <>
            "for ever, so it is metadata only.",
        since: "0.6.0",
        emitter: AuroraMeter.Credits.Recurrences
      },
      %{
        event: [:aurora_meter, :plans, :transition],
        form: :execute,
        names: [[:aurora_meter, :plans, :transition]],
        measurements: [:count],
        metadata: [
          :from_plan_id,
          :from_version,
          :ref,
          :result,
          :tenant_key,
          :to_plan_id,
          :to_version
        ],
        tags: [:result],
        description: "One applied or refused plan transition.",
        since: "1.0.0",
        emitter: AuroraMeter.Subscriptions.Transitions
      },
      %{
        event: [:aurora_meter, :events, :backfill, :batch],
        form: :execute,
        names: [[:aurora_meter, :events, :backfill, :batch]],
        measurements: [:batches, :scanned, :updated],
        metadata: [:cursor],
        tags: [],
        description:
          "One committed batch of `mix aurora_meter.events.backfill`; `cursor` is " <>
            "the `seq` an interrupted run resumes from.",
        since: "1.0.0",
        emitter: AuroraMeter.Events.Backfill
      },
      %{
        event: [:aurora_meter, :record],
        form: :span,
        names: [
          [:aurora_meter, :record, :start],
          [:aurora_meter, :record, :stop],
          [:aurora_meter, :record, :exception]
        ],
        measurements: [:count, :duration, :monotonic_time, :system_time],
        metadata: [
          :batch_size,
          :durability,
          :feature,
          :kind,
          :projection,
          :result,
          :tenant_key
        ],
        tags: [:result, :kind],
        description:
          "One span per durable write. `result` distinguishes `:inserted`, " <>
            "`:duplicate`, `:conflict`, `:invalid`, `:unavailable` and " <>
            "`:unsupported`; `kind` is `:usage` or `:correction`.",
        since: "1.0.0",
        emitter: AuroraMeter.Events
      },
      %{
        event: [:aurora_meter, :replay, :batch],
        form: :execute,
        names: [[:aurora_meter, :replay, :batch]],
        measurements: [:duration, :keys, :scanned],
        metadata: [:cursor, :generation, :phase],
        tags: [],
        description: "One committed batch of a projection rebuild.",
        since: "1.0.0",
        emitter: AuroraMeter.Events.Replay
      },
      %{
        event: [:aurora_meter, :replay, :phase],
        form: :execute,
        names: [[:aurora_meter, :replay, :phase]],
        measurements: [:duration],
        metadata: [:differences, :drained, :generation, :phase, :resumed, :seeded],
        tags: [],
        description:
          "One per rebuild phase (`:announce`, `:drain`, `:compare`, `:activate`). " <>
            "`phase` is bounded but is not an allow-listed tag name, so the preset " <>
            "maps it onto `kind`.",
        since: "1.0.0",
        emitter: AuroraMeter.Events.Replay
      },
      %{
        event: [:aurora_meter, :operations, :batch],
        form: :execute,
        names: [[:aurora_meter, :operations, :batch]],
        measurements: [:duration_ms, :items],
        metadata: [:name, :result],
        tags: [:result],
        description:
          "One committed batch of any operation run through " <>
            "`AuroraMeter.Operations.run_batches/3`. `name` is the operation name " <>
            "and its scope (`\"credit_expiry:global\"`), so it is bounded by the " <>
            "host's tenants and is metadata only.",
        since: "1.0.0",
        emitter: AuroraMeter.Operations
      },
      %{
        event: [:aurora_meter, :retention, :prune],
        form: :execute,
        names: [[:aurora_meter, :retention, :prune]],
        measurements: [:deleted, :duration],
        metadata: [:blocked, :table],
        tags: [],
        description:
          "One per table `AuroraMeter.Retention.prune/1` examined. `table` is " <>
            "bounded by the retention allow list, so the preset maps it onto `kind`.",
        since: "1.0.0",
        emitter: AuroraMeter.Retention
      }
    ]
  end

  @doc """
  Every concrete event name in the catalogue, flattened.

  ## Examples

      iex> [:aurora_meter, :credits, :grant] in AuroraMeter.Telemetry.event_names()
      true

  """
  @spec event_names() :: [[atom()]]
  def event_names, do: Enum.flat_map(events(), & &1.names)

  @doc """
  A copy of `metadata` safe to put in a log line or a span attribute.

  Everything that identifies a customer, a payment or an object is dropped, and
  so is anything whose name ends in one of `forbidden_tag_suffixes/0`. `error`
  becomes `error_class`: the exception module, or the outcome tag, and never the
  message, which is where a query, a key or a customer's data ends up.

  `:tenant` chooses what happens to `tenant_key`:

    * `:drop` (default) removes it.
    * `:digest` replaces it with `tenant_digest`, the first eight bytes of its
      SHA-256 in lower-case hex. That is **pseudonymous, not anonymous**: it is
      stable, so it still links a person's activity across records, and several
      regimes treat it as personal data.
    * `:raw` keeps it. It is spelled out so that carrying an identifier into a
      monitoring pipeline is a decision somebody wrote down.

  ## Examples

      iex> AuroraMeter.Telemetry.redact(%{tenant_key: "acme", feature: :api_calls})
      %{feature: :api_calls}

      iex> AuroraMeter.Telemetry.redact(%{tenant_key: "acme"}, tenant: :raw)
      %{tenant_key: "acme"}

      iex> AuroraMeter.Telemetry.redact(%{error: %RuntimeError{message: "boom"}})
      %{error_class: "RuntimeError"}

  """
  @spec redact(map(), keyword()) :: map()
  def redact(metadata, opts \\ []) when is_map(metadata) and is_list(opts) do
    tenant = Keyword.get(opts, :tenant, :drop)

    unless tenant in [:drop, :digest, :raw] do
      raise ArgumentError,
            "AuroraMeter.Telemetry.redact/2 :tenant must be :drop, :digest or :raw, got: " <>
              inspect(tenant)
    end

    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc -> put_redacted(acc, key, value, tenant) end)
  end

  defp put_redacted(acc, :error, value, _tenant),
    do: Map.put(acc, :error_class, error_class(value))

  defp put_redacted(acc, :tenant_key, value, :digest),
    do: Map.put(acc, :tenant_digest, digest(value))

  defp put_redacted(acc, :tenant_key, value, :raw), do: Map.put(acc, :tenant_key, value)
  defp put_redacted(acc, :tenant_key, _value, :drop), do: acc

  defp put_redacted(acc, key, value, _tenant) do
    cond do
      key in @redact_drop -> acc
      forbidden_suffix?(key) -> acc
      true -> Map.put(acc, key, value)
    end
  end

  defp error_class(%{__struct__: module, __exception__: true}), do: inspect(module)
  defp error_class(tag) when is_atom(tag), do: tag
  defp error_class({tag, _detail}) when is_atom(tag), do: tag
  defp error_class(_other), do: :unknown

  defp digest(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  defp digest(value), do: digest(to_string(value))

  @doc """
  Emits every gauge once, synchronously, from the caller's process.

  For a host that has set `metrics_interval: 0` and drives the gauges from
  `telemetry_poller` or its own scheduler. Each gauge is emitted by the process
  that owns the state behind it, so this is a message to `AuroraMeter.Store` and
  another to `AuroraMeter.Cluster`, not a read of their internals.

  A process that is not running contributes no sample, rather than a zero: a
  gauge that reports zero when nothing is watching is worse than a gauge that
  reports nothing, because zero looks healthy.

  ## Examples

      iex> AuroraMeter.Telemetry.emit_gauges()
      :ok

  """
  @spec emit_gauges() :: :ok
  def emit_gauges do
    Store.emit_gauge()
    if Cluster.enabled?(), do: Cluster.emit_lag()
    :ok
  end
end
