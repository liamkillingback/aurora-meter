defmodule AuroraMeter do
  @moduledoc """
  Aurora Meter — real-time usage metering, plan entitlements, and Stripe-ready
  billing primitives for Phoenix.

  Count, gate, and bill on the BEAM: increments hit an in-memory ETS counter
  (microseconds, no database on the hot path), a flusher persists snapshots to
  Postgres on an interval, and a broadcaster fans live values out over
  `Phoenix.PubSub`.

  Add it to your host application's supervision tree — it validates configuration
  at boot and starts the metering runtime:

      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        AuroraMeter,
        MyAppWeb.Endpoint
      ]

  ## Tenants: the first argument everywhere

  Every function takes a tenant first (`org` in the examples). It is whatever
  identifies the customer being metered: the organisation or account that owns
  the subscription, not the individual user. Strings, integers and atoms work
  as they are (`"org_42"`, `42`, `:acme`); to pass your own struct, configure a
  module that implements `AuroraMeter.Tenant`:

      defmodule MyApp.Tenant do
        @behaviour AuroraMeter.Tenant
        def to_key(%MyApp.Accounts.Org{id: id}), do: "org_\#{id}"
        def to_key(key) when is_binary(key), do: key
      end

      config :aurora_meter, tenant: MyApp.Tenant

  The resolved key must be stable and unique per customer: it is the key for the
  ETS counters, the persisted counter rows and the PubSub topics. Subscribe a
  plan (`subscribe/2`) with the same term you meter with.

  ## Counting and recording are two different things

  `track/4` counts. It is the hot path: an ETS increment, no database, and a
  total flushed on an interval. Lose a node and you lose whatever it had not
  flushed, which is the trade that makes it fast.

  `record/4` **records**. It takes an identity you supply and writes one row in
  one transaction with its projected total, so a retry after a timeout is a
  duplicate rather than a second charge. Use it for anything you will invoice.
  `AuroraMeter.Events` is the read side.

  The public API: `track/4`, `record/4`, `record_batch/2`, `usage/2`,
  `usage_all/1`, `history/3` (metering);
  `check/2`, `allowed?/2`, `entitled?/2`, `remaining/2`, `quota/2`,
  `feature_value/3`, `reserve/3`, `with_quota/4` (entitlements);
  `subscribe/2`, `plan/1`, `period/1` (plans).

  Prepaid balances live in `AuroraMeter.Credits`: `grant/3`, `hold/4`,
  `settle/3`, `release/1`, `debit/4` and `with_credits/4` keep a per-tenant
  ledger in micro-dollars, next to (not instead of) the plan counters above.
  """

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Config.Schema, as: ConfigSchema
  alias AuroraMeter.Counter
  alias AuroraMeter.Entitlements
  alias AuroraMeter.Events
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Storage
  alias AuroraMeter.Tenant

  @version Mix.Project.config()[:version]

  @doc """
  Returns the Aurora Meter version.

  ## Examples

      iex> is_binary(AuroraMeter.version())
      true

  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Records `qty` usage of `feature` for `tenant` in the current period.

  `tenant` is any term that identifies the customer (a string, an id, or your
  own struct via a configured `AuroraMeter.Tenant`); see the module docs.

  Runs on the ETS hot path (no database round-trip) unless the feature is durable
  (`opts[:durable]` or configured in `:durable_features`), in which case a raw
  event row is also written. Options: `:durable` (boolean), `:metadata` (map).

  `track/4` never refuses a feature no plan declares: metering is not
  entitlement, and metering a name before it reaches a plan is a reasonable
  thing to do. It reports the condition instead, as `declared:` in
  `[:aurora_meter, :track]` telemetry metadata.

  It does refuse one thing. A feature configured
  `feature_sources: %{name => :events}` raises `ArgumentError`, with or without
  `durable: true`, because its commercial quantity is the sum of the events
  `record/4` committed and counting it here as well would bill the same usage
  twice. The raise happens before the tenant key is resolved and before any ETS
  write, so it leaves nothing behind. See [Metering](metering.md).
  """
  @spec track(term(), atom(), integer(), keyword()) :: :ok
  def track(tenant, feature, qty \\ 1, opts \\ []) do
    feature = feature!(feature)
    buffered_source!(feature)
    tenant_key = Tenant.to_key(tenant)
    period = Period.current!(tenant)
    period_start = period.start
    Counter.incr(tenant_key, feature, qty, period_start)
    maybe_write_event(tenant_key, feature, qty, period, opts)

    # `declared:` here is "does any plan declare this name", not "is this tenant
    # entitled to it". Answering the second would mean resolving the tenant's
    # subscription on `track/4`, and with `subscription_cache_ttl: 0` that is a
    # database read on the hot path, which `architecture-map.md` section 3
    # forbids. `AuroraMeter.entitled?/2` answers the entitlement question.
    :telemetry.execute([:aurora_meter, :track], %{count: qty}, %{
      tenant_key: tenant_key,
      feature: feature,
      declared: Plans.declared_anywhere?(feature)
    })

    :ok
  end

  @doc """
  Records one durable usage fact for `tenant`, identified by `id`.

  This is the billing-grade path, and it is not `track/4`. `track/4` counts in
  memory and flushes a total; `record/4` writes a row with an identity of your
  choosing, in one transaction with its projected total and the configured
  export intent. Because the identity is yours, a retry after an uncertain
  write is a **duplicate** rather than a second charge:

      AuroraMeter.record(org, :api_calls, 1,
        id: request_id,
        occurred_at: request.started_at,
        dimensions: %{"model" => "sonnet"}
      )
      #=> {:ok, %AuroraMeter.Event{}, :inserted}

      # the same call again, after a timeout you never saw the answer to
      #=> {:ok, %AuroraMeter.Event{}, :duplicate}

  **An unknown outcome is retryable with the same `id`, never with a fresh
  one.** Every `{:error, {:unavailable, _}}` means "this may or may not have
  committed"; repeating the call with the same identity is the only safe answer,
  and it is always safe.

  ## Options

    * `:id` (**required**) the caller's identity for this fact: 1 to 128 bytes
      of UTF-8, unique per tenant across every feature. `legacy:`, `track:` and
      `recurring:` are reserved prefixes.
    * `:occurred_at` (**required**) a `DateTime` in `Etc/UTC` saying when the
      usage happened, which is not necessarily now. Old instants are accepted
      and attributed to the period that held them; one more than
      `:events_future_tolerance` seconds ahead is refused.
    * `:dimensions` a map with string keys for breaking the usage down: at most
      32 keys, keys at most 64 bytes, scalar values at most 256 bytes.
    * `:metadata` a map with string keys, at most 16 KiB of JSON.
    * `:future_tolerance` seconds, overriding `:events_future_tolerance`.
    * `:timeout` milliseconds, overriding `:record_timeout`.

  ## Return values

    * `{:ok, event, :inserted}` the fact is committed, with its total and its
      export intent.
    * `{:ok, event, :duplicate}` this identity was already recorded with this
      payload. Nothing was written a second time; `event` is what is stored.
    * `{:error, {:invalid, errors}}` the request never reached the database.
    * `{:error, {:conflict, existing}}` this identity is already recorded with
      a **different** payload. Nothing was written. Use a different id, or send
      the payload that is already there.
    * `{:error, {:unavailable, reason}}` the write may or may not have
      happened. Retry with the same id.
    * `{:error, {:unsupported, :durable_events}}` the configured storage
      adapter does not do durable events.

  There is deliberately no fallback to `track/4`. A refused durable write must
  not become a successful buffered one: the caller would believe a fact was
  recorded that has no identity, no hash and no way to be deduplicated.

  ## Inside your own transaction

  When you call this inside a transaction of your own, the durable work runs on
  a savepoint, the event comes back with `durability: :conditional`, and
  nothing is hydrated or published until you call
  `AuroraMeter.Events.after_commit/1` after your commit. Your rollback removes
  the event, its total and its export intent together.
  """
  @spec record(term(), atom(), pos_integer(), keyword()) ::
          {:ok, AuroraMeter.Event.t(), :inserted | :duplicate}
          | {:error, {:invalid, [{atom(), atom()}]}}
          | {:error, {:conflict, AuroraMeter.Event.t()}}
          | {:error, {:unavailable, term()}}
          | {:error, {:unsupported, :durable_events}}
  def record(tenant, feature, quantity \\ 1, opts \\ []) do
    Events.record(tenant, Events.feature!(feature), quantity, opts)
  end

  @doc """
  Records many durable facts in one transaction.

  Every element is validated first, then all of them are written together:
  either every new row commits or none does. Results come back in input order.

      AuroraMeter.record_batch([
        %{tenant: org, feature: :api_calls, quantity: 1, id: "a", occurred_at: at},
        %{tenant: org, feature: :api_calls, quantity: 4, id: "b", occurred_at: at}
      ])
      #=> {:ok, [{%AuroraMeter.Event{}, :inserted}, {%AuroraMeter.Event{}, :inserted}]}

  Each element takes the same keys as `record/4`'s options, plus `:tenant`,
  `:feature` and `:quantity`. Limits: 500 elements and 1 MiB of encoded
  dimensions and metadata in total, both refused before any database call.

  Repeated ids inside one batch collapse when their payloads are identical, and
  each position still gets its own result. Repeated ids with **different**
  payloads are `{:error, {:invalid, [{index, :id, :duplicate_id_in_batch}]}}`,
  again before any database call.

  One conflicting element rolls the whole batch back with
  `{:error, {:conflict, index, existing}}`: no new row, no totals delta and no
  export intent survives it.
  """
  @spec record_batch([map()], keyword()) ::
          {:ok, [{AuroraMeter.Event.t(), :inserted | :duplicate}]}
          | {:error, {:invalid, [{non_neg_integer(), atom(), atom()}]}}
          | {:error, {:conflict, non_neg_integer(), AuroraMeter.Event.t()}}
          | {:error, {:unavailable, term()}}
          | {:error, {:unsupported, :durable_events}}
  def record_batch(events, opts \\ []) when is_list(events) do
    Events.record_batch(events, opts)
  end

  @doc """
  Corrects a recorded fact by appending a **new** event that reduces it.

  Nothing is ever updated or deleted. A correction is its own row, with its own
  identity, pointing at the event it reduces, and both rows stay in the history
  for ever. That is what makes a corrected invoice explicable six months later.

      AuroraMeter.record(org, :api_calls, 10, id: "req_1", occurred_at: at)
      AuroraMeter.correct(org, "req_1", 3, id: "credit_1", metadata: %{"ticket" => "SUP-42"})
      #=> {:ok, %AuroraMeter.Event{kind: :correction, quantity: 3}, :inserted}

      AuroraMeter.Events.total(org, :api_calls, period.start)
      #=> 7

  `quantity` is the **magnitude of the reduction**: a positive integer, never a
  negative one and never zero. The cumulative magnitude of the corrections of
  one original can never exceed that original's quantity, checked under a lock
  on the original row, so two operators correcting the same fact at the same
  moment cannot between them credit more than was charged.

  A correction belongs to the **original's** period, not to the period it is
  issued in: a September fact corrected in October changes September's invoice.
  It carries the original's feature, plan attribution and dimensions for the
  same reason, and it never reprices.

  ## Options

    * `:id` (**required**) the correction's own identity, with the same rules as
      `record/4`'s. Repeating it is a duplicate, not a second credit, **even
      when the original is by then fully corrected**.
    * `:metadata` a map with string keys: the reason, a ticket reference, an
      operator id.

  `:dimensions` and `:occurred_at` are **refused**, not ignored. A correction
  inherits both, and changing either means reversing the original and recording
  a replacement, which is `replace/4`.

  ## Return values

    * `{:ok, event, :inserted}` the correction is committed, with its negative
      totals delta and its export intent.
    * `{:ok, event, :duplicate}` this correction id is already recorded with
      this payload. Nothing happened a second time.
    * `{:error, {:invalid, errors}}` including `[quantity: :exceeds_original]`
      when the cumulative bound would be broken, and `[original: :is_correction]`
      because corrections of corrections are not supported: correct the
      original instead.
    * `{:error, {:conflict, existing}}` this correction id is recorded with a
      different payload. Choose another id.
    * `{:error, {:not_found, :original}}`.
    * `{:error, {:unavailable, reason}}` retry with the same id.
    * `{:error, {:unsupported, :corrections}}`.

  A refusal does **not** roll back a transaction of your own that wrapped the
  call; a conflict does.

  ## What the provider sees

  Core records every correction and hands every one of them to the export seam
  with a reason attached, including the ones it can already tell are not
  deliverable (a buffered feature, an original whose period could not be
  resolved). Nothing is dropped and nothing is marked settled that was not.
  Whether a correction can still reach Stripe depends on the meter event
  adjustment window, which Aurora Meter Pro decides and quarantines with a
  reconciliation item when it cannot.
  """
  @spec correct(term(), String.t(), pos_integer(), keyword()) ::
          {:ok, AuroraMeter.Event.t(), :inserted | :duplicate}
          | {:error, {:invalid, [{atom(), atom()}]}}
          | {:error, {:conflict, AuroraMeter.Event.t()}}
          | {:error, {:not_found, :original}}
          | {:error, {:unavailable, term()}}
          | {:error, {:unsupported, :corrections}}
  def correct(tenant, original_event_id, quantity, opts \\ []) do
    Events.correct(tenant, original_event_id, quantity, opts)
  end

  @doc """
  Fully reverses a recorded fact and records a replacement, in one transaction.

  This is how a **dimension or a timestamp** is corrected. `correct/4` reduces a
  quantity and inherits everything else; when what was wrong is the model name,
  the region or the instant, the honest record is a full reversal plus a new
  fact, and this writes both or neither.

      AuroraMeter.replace(org, "req_1", %{quantity: 10, occurred_at: at,
                                          dimensions: %{"model" => "opus"}},
        id: "fix_1")
      #=> {:ok, %{correction: %AuroraMeter.Event{}, replacement: %AuroraMeter.Event{}}, :inserted}

  `attrs` takes `:quantity`, `:occurred_at`, `:dimensions` and `:metadata`, the
  same keys `record/4` takes. `:feature` may be given only if it equals the
  original's: a replacement restates the same commercial fact, it does not
  become a different one.

  ## The two ids

  `:id` is the **correction's**. The replacement's is `id <> "~r"` unless you
  pass `:replacement_id`. Deriving it is what makes the whole operation
  idempotent under one caller id: a retry finds both rows and returns
  `:duplicate` for the pair. Because the derived id must still fit 128 bytes,
  `:id` is limited to 126 here, and a longer one is
  `{:invalid, [id: :too_long_for_replacement]}`.

  The correction's magnitude is whatever is left of the original:
  `original.quantity` less the corrections already committed. An original that
  is already fully corrected has nothing to reverse and returns
  `{:invalid, [quantity: :already_fully_corrected]}`; record a new fact instead.

  Both events produce an export intent, in the order correction then
  replacement, so an exporter that must cancel before re-sending sees them that
  way round.
  """
  @spec replace(term(), String.t(), map(), keyword()) ::
          {:ok, %{correction: AuroraMeter.Event.t(), replacement: AuroraMeter.Event.t()},
           :inserted | :duplicate}
          | {:error, {:invalid, [{atom(), atom()}]}}
          | {:error, {:conflict, AuroraMeter.Event.t()}}
          | {:error, {:not_found, :original}}
          | {:error, {:unavailable, term()}}
          | {:error, {:unsupported, :corrections}}
  def replace(tenant, original_event_id, attrs, opts \\ []) do
    Events.replace(tenant, original_event_id, attrs, opts)
  end

  @doc "Returns `tenant`'s usage of `feature` in the current period."
  @spec usage(term(), atom()) :: integer()
  def usage(tenant, feature) do
    Counter.value(Tenant.to_key(tenant), feature!(feature), Period.current!(tenant).start)
  end

  @doc "Returns a map of `feature => value` for `tenant`'s warm counters this period."
  @spec usage_all(term()) :: %{atom() => integer()}
  def usage_all(tenant) do
    Counter.all_for(Tenant.to_key(tenant), Period.current!(tenant).start)
  end

  @doc """
  Returns `tenant`'s daily usage of `feature` as a list of
  `%{date: Date.t(), value: integer()}` points, one per UTC day, oldest first.

  Options: `:days` (default 30, ending today), or explicit `:from` / `:to`
  dates. Days with no usage are present with a value of `0`. Requires
  `:history` (on by default) and schema version 2.

      AuroraMeter.history(org, :ai_generations, days: 7)
      #=> [%{date: ~D[2026-09-01], value: 12}, ..., %{date: ~D[2026-09-07], value: 3}]
  """
  @spec history(term(), atom(), keyword()) :: [Storage.history_point()]
  def history(tenant, feature, opts \\ []) do
    feature = feature!(feature)
    tenant_key = Tenant.to_key(tenant)
    to = Keyword.get(opts, :to, Clock.today())
    days = Keyword.get(opts, :days, 30)
    from = Keyword.get(opts, :from, Date.add(to, -(days - 1)))

    stored =
      tenant_key
      |> Storage.load_history_range(feature, from, to)
      |> Map.new(&{&1.date, &1.value})

    live = Counter.warm_day_values(tenant_key, feature)

    for date <- Date.range(from, to) do
      %{date: date, value: Map.get(live, date) || Map.get(stored, date, 0)}
    end
  end

  @doc "Returns the current billing period for `tenant` (`%{start:, end:, source:}`)."
  @spec period(term()) :: Period.t()
  def period(tenant), do: Period.current!(tenant)

  @doc "Assigns `plan_id` to `tenant` locally. See `AuroraMeter.Entitlements.subscribe/2`."
  @spec subscribe(term(), atom() | String.t()) ::
          {:ok, AuroraMeter.Schema.Subscription.t()} | {:error, Ecto.Changeset.t()}
  defdelegate subscribe(tenant, plan_id), to: AuroraMeter.Entitlements

  @doc """
  Assigns a specific version of `plan_id` to `tenant`.

      AuroraMeter.subscribe(org, :pro, version: "1")

  See `AuroraMeter.Entitlements.subscribe/3`.
  """
  @spec subscribe(term(), atom() | String.t(), keyword()) ::
          {:ok, AuroraMeter.Schema.Subscription.t()} | {:error, Ecto.Changeset.t()}
  defdelegate subscribe(tenant, plan_id, opts), to: AuroraMeter.Entitlements

  @doc "Returns `tenant`'s current plan. See `AuroraMeter.Entitlements.plan/1`."
  @spec plan(term()) :: AuroraMeter.Plan.t() | nil
  defdelegate plan(tenant), to: AuroraMeter.Entitlements

  @doc """
  Checks whether `tenant` may use `feature`. See `AuroraMeter.Entitlements.check/2`.

  Advisory: this reads the counter and compares, so two concurrent callers can
  both see `:ok` at the cap. To enforce a hard limit atomically use
  `reserve/3` or `with_quota/4`.
  """
  @spec check(term(), atom()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  def check(tenant, feature), do: Entitlements.check(tenant, feature!(feature))

  @doc "Whether `check/2` currently returns `:ok`."
  @spec allowed?(term(), atom()) :: boolean()
  def allowed?(tenant, feature), do: Entitlements.allowed?(tenant, feature!(feature))

  @doc "Whether the plan grants access to `feature` (ignores quota)."
  @spec entitled?(term(), atom()) :: boolean()
  def entitled?(tenant, feature), do: Entitlements.entitled?(tenant, feature!(feature))

  @doc "Remaining quota for a hard-limited feature, or `:unlimited`."
  @spec remaining(term(), atom()) :: non_neg_integer() | :unlimited
  def remaining(tenant, feature), do: Entitlements.remaining(tenant, feature!(feature))

  @doc """
  The value of a `feature :name, value` declaration on `tenant`'s plan
  (a boolean or a non-negative integer), or `default` when the plan does not
  carry one. See `AuroraMeter.Entitlements.feature_value/3`.

      AuroraMeter.feature_value(org, :seats, 1)   # => 5
  """
  @spec feature_value(term(), atom(), default) :: boolean() | non_neg_integer() | default
        when default: term()
  def feature_value(tenant, feature, default \\ nil),
    do: Entitlements.feature_value(tenant, feature!(feature), default)

  @doc "A dashboard-ready quota snapshot. See `AuroraMeter.Entitlements.quota/2`."
  @spec quota(term(), atom()) :: Entitlements.quota()
  def quota(tenant, feature), do: Entitlements.quota(tenant, feature!(feature))

  @doc "Atomically reserves usage against the plan. See `AuroraMeter.Entitlements.reserve/3`."
  @spec reserve(term(), atom()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  def reserve(tenant, feature), do: Entitlements.reserve(tenant, feature!(feature))

  @doc "Atomically reserves `qty` usage against the plan."
  @spec reserve(term(), atom(), pos_integer()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  def reserve(tenant, feature, qty), do: Entitlements.reserve(tenant, feature!(feature), qty)

  @doc "Gates, runs, and meters in one step. See `AuroraMeter.Entitlements.with_quota/4`."
  @spec with_quota(term(), atom(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_quota(tenant, feature, fun) when is_function(fun, 0),
    do: Entitlements.with_quota(tenant, feature!(feature), fun)

  @doc "Gates, runs, and meters `qty` in one step."
  @spec with_quota(term(), atom(), pos_integer(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_quota(tenant, feature, qty, fun) when is_function(fun, 0),
    do: Entitlements.with_quota(tenant, feature!(feature), qty, fun)

  # The one place a feature name is checked. Features are keyed as atoms in ETS
  # and stored as strings in the database, so tracking `"api"` and `:api` keeps
  # two in-memory counters that seed from and flush into one database row (open
  # finding C4). The rejection is a facade rule: `AuroraMeter.Storage`
  # callbacks keep taking `atom() | String.t()`, because stored rows carry
  # strings and Pro reads them back.
  #
  # The return type is deliberately `term()`: in the transition release a binary
  # is warned about and passed through unchanged, so a 0.5.x upgrade breaks
  # nobody.
  #
  # `mode` is a parameter, and the arity-2 form is public but undocumented, so
  # the suite can exercise both halves of the transition without depending on
  # the package's own version.
  @doc false
  @spec feature!(term(), ConfigSchema.mode()) :: term()
  def feature!(feature, mode \\ ConfigSchema.mode())

  def feature!(feature, _mode) when is_atom(feature), do: feature

  def feature!(feature, :strict) when is_binary(feature) do
    raise ArgumentError, binary_feature_message(feature, :strict)
  end

  def feature!(feature, :transition) when is_binary(feature) do
    ConfigSchema.warn_once(:binary_feature, feature, fn ->
      binary_feature_message(feature, :transition)
    end)

    feature
  end

  def feature!(feature, _mode) do
    raise ArgumentError,
          "feature names are atoms; got #{inspect(feature, limit: 3, printable_limit: 64)}."
  end

  @spec binary_feature_message(String.t(), :strict | :transition) :: String.t()
  defp binary_feature_message(feature, mode) do
    atom = ":" <> feature

    "feature names are atoms; got #{inspect(feature)}. Use #{atom}. (Aurora Meter stores " <>
      "features as strings but keys them as atoms, so passing a string creates a second " <>
      "in-memory counter for the same database row.) " <> binary_feature_tail(mode)
  end

  @spec binary_feature_tail(:strict | :transition) :: String.t()
  defp binary_feature_tail(:strict), do: ""

  defp binary_feature_tail(:transition) do
    "This version keeps the old behaviour and warns once per name; Aurora Meter 1.0 raises. " <>
      "The stored row is already keyed by the string form, so switching to the atom keeps " <>
      "the history."
  end

  # The one refusal on the `track/4` path, and it is I08's: a feature whose
  # commercial quantity comes from durable events must not also be counted into
  # the buffered path, because the flusher would write it to
  # `aurora_meter_counters` and a reporter bills that table.
  #
  # It is checked before `Tenant.to_key/1` and before any ETS write on purpose:
  # a guard that fires after a partial mutation leaves the thing it was meant to
  # prevent, half-done.
  #
  # A binary feature name reaches here in the transition release (see
  # `feature!/2`), and never matches: `:feature_sources` is keyed by atoms. That
  # is correct rather than a gap, because a binary feature is already a warned
  # deprecation on its way to an `ArgumentError` of its own in 1.0.
  @spec buffered_source!(term()) :: :ok
  defp buffered_source!(feature) do
    if Config.feature_source(feature) == :events do
      raise ArgumentError,
            "#{inspect(feature)} is an events-source feature; use AuroraMeter.record/4. " <>
              "Tracking it would create a second, separately billable count: its " <>
              "commercial quantity is the sum of the events recorded for it, and an ETS " <>
              "increment would be flushed to aurora_meter_counters and reported as well. " <>
              "`config :aurora_meter, feature_sources: %{#{inspect(feature)} => :buffered}` " <>
              "restores tracking, and is a period-boundary decision, not a call-site one."
    end

    :ok
  end

  # The legacy durable-track path. It is kept working and is deprecated; nothing
  # reads these rows for billing and nothing deduplicates them. The row's
  # identity rule lives in `AuroraMeter.Storage.Ecto.insert_events/1`; what is
  # decided here is that the row is charged to the period the counter was just
  # bumped in, resolved once, rather than to a second lookup that could land on
  # the other side of a boundary from the increment it accompanies.
  @spec maybe_write_event(String.t(), atom(), integer(), Period.t(), keyword()) :: :ok
  defp maybe_write_event(tenant_key, feature, qty, period, opts) do
    if durable?(feature, opts) do
      write_legacy_event(tenant_key, feature, qty, period, opts)
    end

    :ok
  end

  # The rescue adds a log line and nothing else. It re-raises because swallowing
  # the failure would leave the ETS counter bumped and the caller believing the
  # row exists, which is worse than the exception it already got
  # (`open-findings.md` C14). What the log adds is the tenant and the feature:
  # without them the exception names a repo and a table and the operator cannot
  # tell whose usage lost its row.
  #
  # The disagreement C14 records is NOT fixed here and must not be claimed to
  # be: inside a host transaction this insert joins that transaction and rolls
  # back with it, while the ETS bump survives and will flush. `record/4` is the
  # path with no such window.
  @spec write_legacy_event(String.t(), atom(), integer(), Period.t(), keyword()) :: :ok
  defp write_legacy_event(tenant_key, feature, qty, period, opts) do
    Storage.insert_events([
      %{
        tenant_key: tenant_key,
        feature: feature,
        quantity: qty,
        metadata: Map.new(Keyword.get(opts, :metadata, %{})),
        period_start: period.start,
        period_source: period.source
      }
    ])
  rescue
    error ->
      Logger.error(
        "AuroraMeter durable event write failed for #{inspect(tenant_key)}/" <>
          "#{inspect(feature)}: " <> Exception.message(error)
      )

      reraise error, __STACKTRACE__
  end

  @spec durable?(atom(), keyword()) :: boolean()
  defp durable?(feature, opts) do
    Keyword.get(opts, :durable, false) or feature in Config.durable_features()
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Validates configuration, starts the Aurora Meter runtime supervisor, and
  registers the plan versions.

  Raises `NimbleOptions.ValidationError` if the `:aurora_meter` configuration is
  missing a required key or has a value of the wrong type, and
  `AuroraMeter.PlanVersionConflictError` when a compiled plan version's
  commercial content differs from the snapshot already registered for it
  (`plan_version_conflict: :warn` logs the same message instead).

  `AuroraMeter.Plans.register!/0` runs only when the supervisor actually
  started. `{:error, {:already_started, _}}` is a legitimate answer for a host
  that starts Aurora Meter twice, and registering a second time there would do
  the work twice for no reason.

  Starting Aurora Meter **below** the host's Repo is what lets registration
  happen at boot. Above it, registration is deferred with one warning and
  retried on the first lookup that needs a stored snapshot, rather than failing:
  in 0.4.0 `start_link/1` did no database work at all, and this release is not
  entitled to turn a supervision order that used to work into a failed boot.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    AuroraMeter.Config.validate!()

    case AuroraMeter.Supervisor.start_link(opts) do
      {:ok, pid} ->
        AuroraMeter.Plans.register!()
        {:ok, pid}

      other ->
        other
    end
  end
end
