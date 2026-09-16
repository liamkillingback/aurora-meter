defmodule AuroraMeter.Events do
  @moduledoc """
  Reading, streaming and totalling the durable usage facts that
  `AuroraMeter.record/4` writes.

  `AuroraMeter.track/4` counts; `AuroraMeter.record/4` **records**. A recorded
  event has a caller-supplied identity, a payload hash, a transaction of its
  own and a projected total, so a retry after an uncertain write is a duplicate
  rather than a second charge. This module is the read side of that, plus the
  one function a host needs when it wraps `record/4` in a transaction of its
  own.

  ## When the host owns the transaction

  Inside a host transaction Aurora Meter cannot know when, or whether, the
  commit happens. So it does the durable work on a savepoint, returns the event
  with `durability: :conditional`, and performs **no** ETS hydration and **no**
  PubSub broadcast. The host calls `after_commit/1` once, after its own commit:

      MyApp.Repo.transaction(fn ->
        {:ok, event, :inserted} = AuroraMeter.record(org, :api_calls, 1, id: id, occurred_at: at)
        ...
        event
      end)
      |> case do
        {:ok, event} -> AuroraMeter.Events.after_commit([event])
        {:error, _reason} -> :ok
      end

  Forgetting the call costs nothing durable: the row, its total and the export
  intent all committed with the host's transaction. Only the in-memory view
  stays low until the next cold seed, and `total/3` is authoritative either way.
  """

  require Logger

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Event
  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Events.Gate
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Storage
  alias AuroraMeter.Tenant

  @typedoc "Everything `AuroraMeter.record/4` and `record_batch/2` can go wrong with."
  @type error ::
          {:invalid, [{atom(), atom()}]}
          | {:conflict, Event.t()}
          | {:unavailable, term()}
          | {:unsupported, :durable_events}

  @typedoc "Everything `AuroraMeter.correct/4` and `replace/4` can go wrong with."
  @type correction_error ::
          {:invalid, [{atom(), atom()}]}
          | {:conflict, Event.t()}
          | {:not_found, :original}
          | {:unavailable, term()}
          | {:unsupported, :corrections}

  @doc """
  Reads one recorded event by the identity its caller gave it.

  ## Examples

      iex> AuroraMeter.Events.get("org_no_such_tenant", "no-such-event")
      {:error, :not_found}

  """
  @spec get(term(), String.t()) :: {:ok, Event.t()} | {:error, :not_found | error()}
  def get(tenant, event_id) when is_binary(event_id) do
    Storage.load_event(Tenant.to_key(tenant), event_id)
  end

  @doc """
  The durable total for one feature and period, from the active projection
  generation.

  This is the authoritative number. `AuroraMeter.usage/2` reads the in-memory
  counter, which is a view and may lag; this reads what was committed.

  ## Examples

      iex> AuroraMeter.Events.total("org_no_such_tenant", :api_calls, ~U[2026-01-01 00:00:00Z])
      0

  """
  @spec total(term(), atom(), DateTime.t()) :: non_neg_integer()
  def total(tenant, feature, period_start) do
    case Storage.load_event_total(Tenant.to_key(tenant), feature, period_start) do
      {:ok, %{quantity: quantity}} -> quantity
      {:error, _reason} -> 0
    end
  end

  @doc """
  The durable total and the event count for one feature and period.

  ## Examples

      iex> AuroraMeter.Events.count("org_no_such_tenant", :api_calls, ~U[2026-01-01 00:00:00Z])
      %{quantity: 0, events: 0}

  """
  @spec count(term(), atom(), DateTime.t()) :: %{
          quantity: non_neg_integer(),
          events: non_neg_integer()
        }
  def count(tenant, feature, period_start) do
    case Storage.load_event_total(Tenant.to_key(tenant), feature, period_start) do
      {:ok, total} -> total
      {:error, _reason} -> %{quantity: 0, events: 0}
    end
  end

  @doc """
  A lazy stream of recorded events in insertion order.

  Ordered by `seq`, the database-assigned identity column, and **not** by `id`:
  event ids are random v4 UUIDs, so a keyset scan ordered by one can miss a row
  committed by a transaction that started earlier. One bounded query per chunk,
  never a `Repo.stream` inside an implicit transaction, so a consumer may stop
  at any point without holding a connection open.

  Options: `:after_seq` (default `0`), `:limit` (rows per query, default
  `1000`), `:tenant`, `:feature`, `:from` and `:to` (on `occurred_at`,
  half-open).

  ## Examples

      iex> AuroraMeter.Events.stream(tenant: "org_no_such_tenant") |> Enum.take(1)
      []

  """
  @spec stream(keyword()) :: Enumerable.t()
  def stream(opts \\ []) do
    {after_seq, opts} = Keyword.pop(opts, :after_seq, 0)
    opts = Keyword.update(opts, :tenant, nil, &if(&1, do: Tenant.to_key(&1)))

    Stream.resource(
      fn -> after_seq end,
      fn
        :done ->
          {:halt, :done}

        cursor ->
          case Storage.stream_events(cursor, opts) do
            {:ok, []} -> {:halt, :done}
            {:ok, events} -> {events, List.last(events).seq}
            {:error, _reason} -> {:halt, :done}
          end
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Applies the in-memory projection and publishes, for events recorded inside a
  transaction the host owned.

  Call it **once**, after the host's own commit, with the events `record/4`
  returned. It holds no state: calling it twice applies the in-memory delta
  twice, which double counts the advisory value `AuroraMeter.usage/2` reads
  until the next cold seed. It is a no-op for an event that is already
  `durability: :durable`, because that one's effects were applied when it
  committed.

  ## Examples

      iex> AuroraMeter.Events.after_commit([])
      :ok

  """
  @spec after_commit([Event.t()] | Event.t()) :: :ok
  def after_commit(%Event{} = event), do: after_commit([event])

  def after_commit(events) when is_list(events) do
    events
    |> Enum.filter(&(&1.durability == :conditional))
    |> Enum.each(&post_commit(&1, :inserted))

    :ok
  end

  # -- the write path (called by the facade) ---------------------------------

  @doc false
  @spec record(term(), atom(), integer(), keyword()) ::
          {:ok, Event.t(), :inserted | :duplicate} | {:error, error()}
  def record(tenant, feature, quantity, opts) do
    span(%{kind: :usage, feature: feature, batch_size: 1}, fn ->
      with {:ok, entry} <- build(tenant, feature, quantity, opts) do
        [entry] |> write(opts) |> one_result()
      end
    end)
  end

  defp one_result({:ok, [{event, outcome}]}) do
    effect = effects(event, outcome)

    {{:ok, event, outcome}, %{count: event.quantity},
     %{
       result: outcome,
       projection: effect,
       tenant_key: event.tenant_key,
       durability: event.durability
     }}
  end

  defp one_result({:error, {:conflict, _index, existing}}), do: {:error, {:conflict, existing}}
  defp one_result({:error, reason}), do: {:error, reason}

  @doc false
  @spec correct(term(), String.t(), integer(), keyword()) ::
          {:ok, Event.t(), :inserted | :duplicate} | {:error, correction_error()}
  def correct(tenant, original_event_id, quantity, opts) do
    span(%{kind: :correction, feature: nil, batch_size: 1}, fn ->
      with {:ok, request} <- build_correction(tenant, original_event_id, quantity, opts) do
        request |> write_correction(opts) |> one_correction()
      end
    end)
  end

  defp one_correction({:ok, [{event, outcome}]}) do
    effect = effects(event, outcome)

    {{:ok, event, outcome}, %{count: event.quantity},
     %{
       result: outcome,
       feature: event.feature,
       projection: effect,
       tenant_key: event.tenant_key,
       durability: event.durability
     }}
  end

  defp one_correction({:error, {:conflict, _index, existing}}),
    do: {:error, {:conflict, existing}}

  defp one_correction({:error, reason}), do: {:error, reason}

  @doc false
  @spec replace(term(), String.t(), map(), keyword()) ::
          {:ok, %{correction: Event.t(), replacement: Event.t()}, :inserted | :duplicate}
          | {:error, correction_error()}
  def replace(tenant, original_event_id, attrs, opts) do
    span(%{kind: :correction, feature: nil, batch_size: 2}, fn ->
      with {:ok, request} <- build_replacement(tenant, original_event_id, attrs, opts) do
        request |> write_correction(opts) |> replaced()
      end
    end)
  end

  defp replaced({:ok, [{correction, outcome}, {replacement, outcome}]}) do
    effect = merge_effect(effects(correction, outcome), effects(replacement, outcome))

    {{:ok, %{correction: correction, replacement: replacement}, outcome},
     %{count: replacement.quantity + correction.quantity},
     %{
       result: outcome,
       feature: replacement.feature,
       projection: effect,
       tenant_key: replacement.tenant_key,
       durability: replacement.durability
     }}
  end

  defp replaced({:error, {:conflict, _index, existing}}), do: {:error, {:conflict, existing}}
  defp replaced({:error, reason}), do: {:error, reason}

  # The replacement travels in the options rather than in the entry: the entry
  # is the correction, and an adapter that supports corrections but not
  # `replace/4` can refuse one option without having to understand a second
  # shape of entry.
  defp write_correction(request, opts) do
    {replacement, entry} = Map.pop(request, :replacement)
    storage = Keyword.put(storage_opts(opts), :replacement, replacement)

    admit(fn -> Storage.record_correction(entry, storage) end)
  end

  defp write(entries, opts) do
    admit(fn -> Storage.record_events(entries, storage_opts(opts)) end)
  end

  @doc false
  @spec record_batch([map()], keyword()) ::
          {:ok, [{Event.t(), :inserted | :duplicate}]}
          | {:error,
             {:invalid, [{non_neg_integer(), atom(), atom()}]}
             | {:conflict, non_neg_integer(), Event.t()}
             | {:unavailable, term()}
             | {:unsupported, :durable_events}}
  def record_batch(events, opts) when is_list(events) do
    span(%{kind: :usage, feature: nil, batch_size: length(events)}, fn ->
      with {:ok, entries, plan} <- build_batch(events, opts) do
        entries |> write(opts) |> batch_result(plan)
      end
    end)
  end

  defp batch_result({:ok, results}, plan) do
    effect =
      Enum.reduce(results, :ok, fn {event, outcome}, acc ->
        merge_effect(acc, effects(event, outcome))
      end)

    # `plan` maps every input position to the result it takes, which is how a
    # collapsed repeat of one id still gets its own entry in the caller's order.
    ordered = Enum.map(plan, &Enum.at(results, &1))
    count = Enum.reduce(ordered, 0, fn {event, _outcome}, sum -> sum + event.quantity end)

    {{:ok, ordered}, %{count: count},
     %{result: :inserted, projection: effect, durability: durability(ordered)}}
  end

  defp batch_result({:error, reason}, _plan), do: {:error, reason}

  # One span around the whole durable write, so an OpenTelemetry bridge can open
  # it before the database work starts and Ecto's own spans nest inside it
  # (`api-change-map.md` 1.6). The function hands back its result plus the
  # measurements and metadata for `:stop`; an ordinary error tuple is a result,
  # not an exception, so it is reported in the metadata rather than as
  # `:exception`.
  defp span(metadata, fun) do
    :telemetry.span([:aurora_meter, :record], metadata, fn ->
      case fun.() do
        {result, measurements, extra} ->
          {result, measurements, Map.merge(metadata, extra)}

        {:error, {tag, _detail}} = error ->
          {error, %{count: 0}, Map.put(metadata, :result, tag)}

        {:error, tag} = error ->
          {error, %{count: 0}, Map.put(metadata, :result, tag)}
      end
    end)
  end

  defp merge_effect(:projection_failed, _other), do: :projection_failed
  defp merge_effect(_acc, effect), do: effect

  defp durability([{%Event{durability: durability}, _outcome} | _rest]), do: durability
  defp durability([]), do: :durable

  @doc false
  # The durable path validates feature names strictly in **every** release,
  # including the 0.5.x transition one. The transition allowance exists to keep
  # 0.4.x callers of `track/4` working while they are corrected; `record/4` is
  # new in 1.0 and has no such caller, and a binary feature here would key the
  # ETS projection under one name and the stored row under another for a fact
  # that will be invoiced.
  @spec feature!(term()) :: atom()
  def feature!(feature), do: AuroraMeter.feature!(feature, :strict)

  # -- admission -------------------------------------------------------------

  # The permit is held for exactly as long as the storage call, and returned in
  # an `after` so an ordinary exception cannot leak it. A caller killed with
  # `:kill` runs no `after` at all, which is why the gate monitors its callers
  # rather than trusting this block.
  defp admit(fun) do
    case Gate.enter() do
      {:ok, permit} ->
        try do
          fun.()
        after
          Gate.leave(permit)
        end

      {:error, :overloaded} ->
        {:error, {:unavailable, :overloaded}}

      {:error, :unavailable} ->
        {:error, {:unavailable, :gate_unavailable}}
    end
  end

  defp storage_opts(opts) do
    [
      timeout: Keyword.get(opts, :timeout) || Config.record_timeout(),
      outbox: Config.events_outbox() || AuroraMeter.Events.Outbox.Noop
    ]
  end

  # -- validation and period attribution -------------------------------------

  defp build(tenant, feature, quantity, opts) do
    with :ok <- declared(tenant, feature, :record),
         {:ok, canonical} <- validate(tenant, feature, quantity, opts) do
      {:ok, attribute(tenant, canonical)}
    end
  end

  # A correction states its own id, the id it reduces and a magnitude, and
  # inherits everything else from the original inside the transaction that
  # reads it under lock (L-03e-2). There is deliberately no feature policy check
  # here: the feature is the original's, and it was checked when the original
  # was recorded. Refusing to correct a fact because its feature was later
  # removed from the plan would leave a customer over-billed with no way back.
  #
  # A non-integer magnitude becomes `nil` so that `:remaining`, which is
  # `replace/4`'s internal magnitude, is refused here like any other non-integer
  # rather than silently meaning "reverse the whole thing".
  defp build_correction(tenant, original_event_id, quantity, opts) do
    draft =
      %{
        tenant_key: tenant_key(tenant),
        id: Keyword.get(opts, :id),
        original_event_id: original_event_id,
        quantity: if(is_integer(quantity), do: quantity, else: nil),
        metadata: Keyword.get(opts, :metadata)
      }
      |> forbid(opts, :dimensions)
      |> forbid(opts, :occurred_at)

    case Canonical.validate_correction(draft) do
      {:ok, request} -> {:ok, Map.put(request, :replacement, nil)}
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  defp forbid(draft, opts, key) do
    case Keyword.get(opts, key) do
      nil -> draft
      value -> Map.put(draft, key, value)
    end
  end

  # `replace/4` is a full reversal of the original plus one new record, in one
  # transaction. The replacement's own feature is the original's, so the
  # original is read once WITHOUT a lock to learn it: that read decides nothing
  # financial, because the transaction re-reads the original under `FOR UPDATE`
  # and refuses a replacement whose feature is not the one it finds. An event's
  # feature never changes, so a stale answer here is not reachable either.
  defp build_replacement(tenant, original_event_id, attrs, opts) do
    with {:ok, replacement_id} <- replacement_ids(opts),
         {:ok, correction} <- build_correction(tenant, original_event_id, 1, opts),
         {:ok, original} <- Storage.load_event(tenant_key(tenant), original_event_id),
         {:ok, feature} <- replacement_feature(original, attrs),
         {:ok, entry} <- replacement_entry(tenant, feature, replacement_id, attrs, opts) do
      {:ok, %{correction | quantity: :remaining, replacement: entry}}
    else
      {:error, :not_found} -> {:error, {:not_found, :original}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The replacement's id is derived from the correction's unless the caller
  # overrides it, which is what makes the whole two-row operation idempotent
  # under one caller id: a retry finds both rows and returns `:duplicate`. The
  # derived id must still fit the column, so the caller's own id is two bytes
  # shorter here than elsewhere, and is told so by name.
  defp replacement_ids(opts) do
    id = Keyword.get(opts, :id)
    suffix = "~r"

    cond do
      Keyword.has_key?(opts, :replacement_id) -> {:ok, Keyword.get(opts, :replacement_id)}
      not is_binary(id) -> {:ok, id}
      byte_size(id) + byte_size(suffix) > Canonical.id_limit() -> {:error, too_long_for_replace()}
      true -> {:ok, id <> suffix}
    end
  end

  defp too_long_for_replace, do: {:invalid, [id: :too_long_for_replacement]}

  defp replacement_feature(original, attrs) do
    case Map.get(attrs, :feature) do
      nil -> {:ok, original.feature}
      same when same == original.feature -> {:ok, original.feature}
      _other -> {:error, {:invalid, [feature: :differs_from_original]}}
    end
  end

  defp replacement_entry(tenant, feature, replacement_id, attrs, opts) do
    draft = %{
      tenant_key: tenant_key(tenant),
      feature: feature!(feature),
      quantity: Map.get(attrs, :quantity),
      id: replacement_id,
      occurred_at: Map.get(attrs, :occurred_at),
      dimensions: Map.get(attrs, :dimensions),
      metadata: Map.get(attrs, :metadata),
      kind: :usage,
      original_event_id: nil,
      future_tolerance: Keyword.get(opts, :future_tolerance) || Config.events_future_tolerance()
    }

    case Canonical.validate(draft) do
      {:ok, canonical} -> {:ok, attribute(tenant, canonical)}
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  defp build_batch(events, opts) do
    # `Period.containing/2` takes the caller's own tenant term, because a custom
    # period source may key on the struct rather than on the resolved string.
    # The terms are carried alongside the entries, by resolved key.
    terms = Map.new(events, fn event -> {tenant_key(event[:tenant]), event[:tenant]} end)

    with :ok <- declared_batch(events),
         drafts = drafts(events, opts),
         {:ok, entries, plan} <- wrap_batch(Canonical.validate_batch(drafts)) do
      attributed =
        Enum.map(entries, fn entry ->
          attribute(Map.get(terms, entry.tenant_key, entry.tenant_key), entry)
        end)

      {:ok, attributed, plan}
    end
  end

  defp drafts(events, opts) do
    now = AuroraMeter.Clock.now()
    tolerance = Keyword.get(opts, :future_tolerance) || Config.events_future_tolerance()

    Enum.map(events, fn event ->
      %{
        tenant_key: tenant_key(event[:tenant]),
        feature: feature!(event[:feature]),
        quantity: event[:quantity],
        id: event[:id],
        occurred_at: event[:occurred_at],
        dimensions: event[:dimensions],
        metadata: event[:metadata],
        kind: :usage,
        original_event_id: nil,
        future_tolerance: tolerance,
        now: now
      }
    end)
  end

  defp wrap_batch({:ok, entries, plan}), do: {:ok, entries, plan}
  defp wrap_batch({:error, errors}), do: {:error, {:invalid, errors}}

  defp validate(tenant, feature, quantity, opts) do
    draft = %{
      tenant_key: tenant_key(tenant),
      feature: feature,
      quantity: quantity,
      id: Keyword.get(opts, :id),
      occurred_at: Keyword.get(opts, :occurred_at),
      dimensions: Keyword.get(opts, :dimensions),
      metadata: Keyword.get(opts, :metadata),
      kind: :usage,
      original_event_id: nil,
      future_tolerance: Keyword.get(opts, :future_tolerance) || Config.events_future_tolerance()
    }

    case Canonical.validate(draft) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  # `Tenant.to_key/1` raises in 1.0 for an empty key and warns in the
  # transition release. The canonical validator refuses an empty key on this
  # path under both, because a financial row keyed by "" is not something to
  # warn about and then write.
  defp tenant_key(tenant) do
    Tenant.to_key(tenant)
  rescue
    ArgumentError -> ""
  end

  defp declared_batch(events) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {event, index}, :ok ->
      case declared(event[:tenant], feature!(event[:feature]), :record_batch) do
        :ok ->
          {:cont, :ok}

        {:error, {:invalid, [{field, reason}]}} ->
          {:halt, {:error, {:invalid, [{index, field, reason}]}}}
      end
    end)
  end

  defp declared(_tenant, nil, _entry_point), do: :ok

  defp declared(tenant, feature, entry_point) do
    case AuroraMeter.Entitlements.feature_policy(tenant, feature, entry_point) do
      :allow -> :ok
      :deny -> {:error, {:invalid, [feature: :undeclared]}}
    end
  end

  # `Period.containing/2` raises `AuroraMeter.Period.InvalidPeriodError` when
  # the source cannot place the instant, and that raise IS the contract
  # (`period.ex` `containing/2`): a caller that must degrade rather than fail
  # rescues it and records an unresolved attribution rather than guessing a
  # period. 03a's backfill does exactly this; so does this.
  defp attribute(tenant, canonical) do
    {period_start, period_source, period_attribution} = period(tenant, canonical.occurred_at)
    {plan_id, plan_version, attribution} = plan(tenant, canonical.occurred_at, period_attribution)

    canonical
    |> Map.put(:period_start, DateTime.truncate(period_start, :second))
    |> Map.put(:period_source, period_source)
    |> Map.put(:attribution, attribution)
    |> Map.put(:kind, "usage")
    |> Map.put(:plan_id, plan_id)
    |> Map.put(:plan_version, plan_version)
  end

  defp period(tenant, occurred_at) do
    period = Period.containing(tenant, occurred_at)
    {period.start, inspect(Config.period_source()), "resolved"}
  rescue
    _error ->
      fallback = Period.Calendar.current(tenant, occurred_at)
      {fallback.start, inspect(Period.Calendar), "unresolved"}
  end

  # The plan stamp (build unit 07c, task 07.08, L17.12): resolved **once**, here,
  # from the assignment in force when the usage occurred. No later process
  # recomputes it, so a plan redeploy or a plan change cannot reprice a fact that
  # is already recorded (D05).
  #
  # `attribution` grades the whole row rather than one column of it, and the
  # three values are ordered by how much of the row is an approximation:
  # `"resolved"` is period and plan both placed, `"plan_unresolved"` is a real
  # period with no commercial contract to name, and `"unresolved"` is a period
  # the source could not place at all, which leaves the plan untrustworthy too
  # even when `effective_for/2` would have answered. A period this code had to
  # guess is not an instant worth resolving a contract against, so the plan is
  # not even asked for: that is the one ordering here that matters.
  defp plan(_tenant, _occurred_at, "unresolved"), do: {nil, nil, "unresolved"}

  defp plan(tenant, occurred_at, "resolved") do
    case Plans.effective_for(tenant, occurred_at) do
      {:ok, {plan_id, version}} -> {Atom.to_string(plan_id), version, "resolved"}
      {:error, :unresolved} -> {nil, nil, "plan_unresolved"}
    end
  end

  # -- post-commit effects ---------------------------------------------------

  # The durable fact is the commit. Everything below is a view of it, so a
  # failure in any of it is logged and the call still returns `{:ok, ...}`:
  # turning a committed event into an error would make the caller retry a fact
  # that is already recorded.
  @doc false
  @spec effects(Event.t(), :inserted | :duplicate) :: :ok | :projection_failed
  def effects(%Event{durability: :conditional}, _outcome), do: :ok
  def effects(%Event{}, :duplicate), do: :ok
  def effects(%Event{} = event, :inserted), do: post_commit(event, :inserted)

  defp post_commit(event, _outcome) do
    result = project(event)
    publish(event)
    result
  end

  # Only the current period is hydrated. `AuroraMeter.usage/2` reads the current
  # period and nothing else, and hydrating arbitrary past periods would grow the
  # ETS table without bound as late facts and backfills arrive. The durable
  # total stays authoritative for every period through `total/3`.
  defp project(event) do
    current = Period.current!(event.tenant_key).start

    if DateTime.compare(current, event.period_start) == :eq do
      Counter.apply_projection(
        {event.tenant_key, event.feature, event.period_start},
        projection_delta(event)
      )
    end

    :ok
  rescue
    error ->
      Logger.error(
        "AuroraMeter: the in-memory projection of event #{inspect(event.event_id)} failed " <>
          "(#{Exception.message(error)}). The event is committed and " <>
          "AuroraMeter.Events.total/3 is authoritative; the in-memory value corrects itself " <>
          "on the next cold read."
      )

      :projection_failed
  end

  # The signed contribution one event makes to a total: a usage event adds its
  # quantity, a correction subtracts its magnitude. The durable side of the
  # same rule is in `AuroraMeter.Storage.Ecto`'s correction transaction, and a
  # replay (03d) must apply it too, which is what makes `event_totals.quantity`
  # for a key the sum of its usage events less the sum of its corrections
  # (L-03e-3).
  @spec projection_delta(Event.t()) :: integer()
  defp projection_delta(%Event{kind: :correction, quantity: quantity}), do: -quantity
  defp projection_delta(%Event{quantity: quantity}), do: quantity

  # The magnitude published is POSITIVE and `kind` says what it means, so a
  # consumer subtracts a `:correction` rather than adding a negative number it
  # might not have thought to expect.
  defp publish(event) do
    Phoenix.PubSub.broadcast(
      Config.pubsub(),
      Broadcaster.topic(event.tenant_key),
      {:aurora_meter, :event,
       %{
         tenant_key: event.tenant_key,
         feature: event.feature,
         event_id: event.event_id,
         quantity: event.quantity,
         period_start: event.period_start,
         kind: event.kind
       }}
    )

    :ok
  rescue
    error ->
      Logger.error(
        "AuroraMeter: publishing event #{inspect(event.event_id)} failed " <>
          "(#{Exception.message(error)}). The event is committed; consumers recover from " <>
          "AuroraMeter.Events.total/3."
      )

      :ok
  end
end
