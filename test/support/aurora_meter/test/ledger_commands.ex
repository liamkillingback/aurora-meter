defmodule AuroraMeter.Test.LedgerCommands do
  @moduledoc """
  Generated ledger histories and the executor that runs one against the real
  database, comparing it with `AuroraMeter.Test.LedgerModel` after **every**
  step (build unit 01e).

  ## Why the generator is state-dependent

  A history of independently random commands is almost all `:not_found` and
  `:insufficient_credits`: it never reaches a settle, an overrun or an expiry,
  which is where the arithmetic actually lives. `command/2` therefore holds its
  own `LedgerModel` and draws only from what is legal (plus, deliberately, a
  measured share of what is not, so the refusal paths are exercised too). The
  executor holds a **second, fresh** model, so a bug in the generator's copy
  cannot mask a disagreement between the executor's copy and the database.

  Every choice the generator makes, references included, is drawn from
  `StreamData`. Nothing calls `Enum.random/1`: a generator with a source of
  randomness StreamData cannot see would shrink into a history that is not the
  one that failed.

  ## Why the comparison is per step

  `v1-release.md` task 01.06 says "after each generated history"; this compares
  after each *command*, which is strictly stronger and names the offending
  command instead of handing back a forty-step history and a wrong total.

  ## Independent connections

  Every history runs on `AuroraMeter.Test.Connections.checkout!/0`
  (`sandbox: false`), for two reasons. The assertions read committed state, and
  `Ledger.remaining_on_grant/3` (`ledger.ex:347`) calls `repo.stream/1`, which
  needs a transaction and would be nested differently inside the sandbox's
  enclosing one than it is in production.

  Rows are removed by `Connections.cleanup!/1`, which is bounded to the
  history's own `model_<integer>` tenant prefix and refuses anything shorter
  than four characters, so a full run leaves every table at its starting count.

  ## Global state this executor has to be careful about

  `Credits.expire_due/1` is not tenant scoped (`ledger.ex:251-259`), so a
  committed promotional grant belonging to some other tenant would be expired by
  this history's call and inflate the count it returns. Before every
  `expire_due` step the executor counts foreign due grants and fails with that
  explanation rather than reporting a false disagreement.
  """

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Config
  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Promotions
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.LedgerModel
  alias Ecto.Adapters.SQL.Sandbox

  @seed_dir "test/regressions/seeds"

  @base ~U[2026-01-01 00:00:00Z]

  # Whole seconds only: `expires_at` is a `utc_datetime` column and
  # `expire_due/1` truncates `now` to the second (`ledger.ex:249`, finding L12),
  # so a sub-second offset would be a difference the schema cannot represent.
  @offsets [60, 3_600, 86_400, 7 * 86_400, 30 * 86_400]

  @doc "The instant every generated history measures its expiries from."
  @spec base_instant() :: DateTime.t()
  def base_instant, do: @base

  @doc "The directory saved counterexamples are written to."
  @spec seed_dir() :: String.t()
  def seed_dir, do: @seed_dir

  @doc """
  How many histories a property runs. `AURORA_PROPERTY_RUNS` overrides the
  default of 25, which is chosen so the property adds well under a minute to
  `mix test`; the deep run (500) is where a rare counterexample is found.
  """
  @spec runs(pos_integer()) :: pos_integer()
  def runs(default \\ 25) do
    case System.get_env("AURORA_PROPERTY_RUNS") do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  @doc "Whether V8 is asserted after every step as well as at the end of a history."
  @spec lot_view_per_step?() :: boolean()
  def lot_view_per_step?, do: System.get_env("AURORA_LOT_VIEW") == "1"

  # -- generators -------------------------------------------------------------

  @doc """
  A history of between 5 and 40 commands, each drawn from what the previous ones
  made legal. `:expiry` set to `false` leaves `expire_due` and expiring grants
  out entirely, which is what separates the two properties; `:length` overrides
  the bounds.
  """
  @spec history(keyword()) :: StreamData.t([LedgerModel.command()])
  def history(opts \\ []) do
    {low, high} = Keyword.get(opts, :length, {5, 40})

    StreamData.bind(StreamData.integer(low..high), fn count ->
      build(count, fresh_model(), [], opts)
    end)
  end

  defp build(0, _model, acc, _opts), do: StreamData.constant(Enum.reverse(acc))

  defp build(count, model, acc, opts) do
    StreamData.bind(command(model, opts), fn command ->
      {next, _result} = LedgerModel.apply(model, command)
      build(count - 1, next, [command | acc], opts)
    end)
  end

  @doc """
  One command that makes sense against `model`. Weighted so grants stay ahead of
  spending (an empty wallet generates nothing interesting) while every refusal
  path still appears.
  """
  @spec command(LedgerModel.t(), keyword()) :: StreamData.t(LedgerModel.command())
  def command(model, opts \\ []) do
    seq = model.seq + length(model.commands) + 1

    StreamData.frequency(
      [
        {5, grant_command(model, seq, opts)},
        {4, hold_command(model, seq)},
        {3, debit_command(model, seq)},
        {2, reverse_command(model, seq)}
      ] ++
        close_commands(model, seq) ++
        expire_commands(model, opts)
    )
  end

  defp close_commands(%{holds: holds}, _seq) when map_size(holds) == 0, do: []

  defp close_commands(model, seq),
    do: [{4, settle_command(model, seq)}, {2, release_command(model, seq)}]

  # The three independent draws are taken as one tuple rather than as nested
  # binds: only the expiry depends on what was drawn (a non-promotional grant
  # may not carry one), so only it needs a second stage.
  defp grant_command(model, seq, opts) do
    draws = StreamData.tuple({reference_for(model.refs, :grant, "g#{seq}"), category(), amount()})

    StreamData.bind(draws, fn {reference, category, amount} ->
      StreamData.map(expiry(category, opts), &{:grant, reference, amount, category, &1})
    end)
  end

  defp category, do: StreamData.member_of([:paid, :promotional, :adjustment])

  # Cent boundaries are where a rounding mistake would live, so they get their
  # own weighted tail alongside the uniform range. The ceiling is $50, which
  # keeps a forty-grant history four orders of magnitude inside `bigint`; the
  # boundary itself is covered by named tests rather than by the property (L17).
  defp amount do
    StreamData.frequency([
      {6, StreamData.integer(1..50_000_000)},
      {1, StreamData.member_of([1, 9_999, 10_000, 999_999, 1_000_000, 1_000_001])}
    ])
  end

  # `CreditTransaction.validate_expiry/1` refuses an `expires_at` on anything
  # but a promotional grant, so the generator never produces one.
  defp expiry(:promotional, opts) do
    if Keyword.get(opts, :expiry, true) do
      StreamData.frequency([
        {2, StreamData.constant(nil)},
        {3, StreamData.map(StreamData.member_of(@offsets), &DateTime.add(@base, &1, :second))}
      ])
    else
      StreamData.constant(nil)
    end
  end

  defp expiry(_category, _opts), do: StreamData.constant(nil)

  # Most amounts are affordable and a measured share is exactly one micro-dollar
  # too much, which is the `:insufficient_credits` boundary `sufficient?/2` draws
  # (`ledger.ex:489-490`).
  defp hold_command(model, seq) do
    StreamData.bind(reference_for(model.refs, :hold, "h#{seq}"), fn reference ->
      StreamData.map(spend_amount(model), &{:hold, reference, &1})
    end)
  end

  defp debit_command(model, seq) do
    StreamData.bind(reference_for(model.refs, :debit, "d#{seq}"), fn reference ->
      StreamData.map(spend_amount(model), &{:debit, reference, &1})
    end)
  end

  defp spend_amount(model) do
    head = max(model.balance - model.held + model.tolerance, 0)
    affordable = if head > 0, do: [{4, StreamData.integer(1..head)}], else: []
    StreamData.frequency(affordable ++ [{1, StreamData.constant(head + 1)}])
  end

  # A reversal is never refused for want of balance (`ledger.ex:222`), so its
  # amount is unconstrained; the interesting case is the shared `:debit`
  # reference namespace (L2), which `reference_for/3` reaches by reusing one.
  defp reverse_command(model, seq) do
    StreamData.bind(reference_for(model.refs, :debit, "v#{seq}"), fn reference ->
      StreamData.map(amount(), &{:reverse, reference, &1})
    end)
  end

  defp settle_command(model, seq) do
    StreamData.bind(hold_reference(model, seq), fn reference ->
      cap = settle_cap(model, reference)

      StreamData.map(
        StreamData.frequency([
          {4, StreamData.integer(0..cap)},
          {1, StreamData.integer(cap..(cap * 2 + 1))}
        ]),
        &{:settle, reference, &1}
      )
    end)
  end

  defp release_command(model, seq),
    do: StreamData.map(hold_reference(model, seq), &{:release, &1})

  # Five times out of six a hold this history really took (pending or already
  # closed, which is the `:already_settled` path); once, one that never existed.
  defp hold_reference(model, seq) do
    StreamData.frequency([
      {5, StreamData.member_of(Map.keys(model.holds))},
      {1, StreamData.constant("absent#{seq}")}
    ])
  end

  defp settle_cap(model, reference) do
    case Map.fetch(model.holds, reference) do
      {:ok, %{amount: amount}} -> amount
      :error -> 1_000_000
    end
  end

  # Only instants at which **at most one** grant is due are offered. Two grants
  # falling due in one pass have an undefined outcome, because
  # `ledger.ex:251-259` selects them with no `order_by` while `expire_locked/3`
  # clamps each by the wallet as it stands when its turn comes (finding L19).
  # The model cannot predict an unordered sequence, so the generator does not
  # produce one and a named test records the ambiguity instead.
  defp expire_commands(model, opts) do
    if Keyword.get(opts, :expiry, true) do
      case expire_instants(model) do
        [] -> []
        instants -> [{3, StreamData.map(StreamData.member_of(instants), &{:expire_due, &1})}]
      end
    else
      []
    end
  end

  defp expire_instants(model) do
    live =
      model.grants
      |> Map.values()
      |> Enum.filter(&(&1.expires_at != nil and is_nil(&1.expired_at)))

    (Enum.map(live, & &1.expires_at) ++ [@base])
    |> Enum.uniq()
    |> Enum.filter(fn now -> due_count(live, now) <= 1 end)
  end

  defp due_count(live, now),
    do: Enum.count(live, &(DateTime.compare(&1.expires_at, now) != :gt))

  # A fresh reference four times in five and an existing one the fifth, because
  # a duplicate is not an accident in this ledger: it is what the
  # `(kind, reference)` unique index exists for (`migration.ex:288-293`).
  defp reference_for(refs, namespace, fresh) do
    case for({^namespace, reference} <- refs, do: reference) do
      [] ->
        StreamData.constant(fresh)

      existing ->
        StreamData.frequency([
          {4, StreamData.constant(fresh)},
          {1, StreamData.member_of(existing)}
        ])
    end
  end

  # -- the executor -----------------------------------------------------------

  @doc """
  Runs one history against the real database on an independent connection,
  comparing the model with the database after every command.

  Options: `:seed` and `:label`, both recorded in a saved counterexample, and
  `:cleanup` (default `true`).

  Returns `%{model:, tenant:, view:, steps:}`. Raises `ExUnit.AssertionError` on
  the first disagreement, **after** the counterexample has been written to
  `test/regressions/seeds/`, so a failure is never lost to a shrink that changes
  the input.
  """
  @spec run([tuple()], keyword()) :: map()
  def run(history, opts \\ []) do
    own? = Connections.checkout!()
    tenant = AuroraMeter.Test.unique_tenant("model")

    try do
      final =
        history
        |> Enum.with_index(1)
        |> Enum.reduce(fresh_model(), fn {command, index}, acc ->
          execute(acc, command, index, tenant, history, opts)
        end)

      view = LedgerModel.lot_view(final)
      assert_v8!(view, final, tenant, history, opts)
      report_leak(view, tenant, length(history))

      %{model: final, tenant: tenant, view: view, steps: length(history)}
    rescue
      error ->
        # `cleanup: false` hands the rows to the caller so it can read the
        # aggregates; a raise means there is no caller to hand them to, and rows
        # left behind poison every later history. `expire_due/1` is not tenant
        # scoped (`ledger.ex:251-259`), so one leaked promotional grant turns
        # every subsequent expiry in the run into a false failure, and the run
        # reports a cascade instead of the one disagreement that started it.
        # Observed on 2026-09-14: one counterexample left 30, then 60, then 61
        # foreign due grants behind it.
        Connections.cleanup!(tenant)
        reraise error, __STACKTRACE__
    catch
      {:inconclusive, info} ->
        record_clock_step(info)
        %{tenant: tenant, steps: length(history), inconclusive: info}
    after
      if Keyword.get(opts, :cleanup, true), do: Connections.cleanup!(tenant)
      if own?, do: Sandbox.checkin(Connections.repo())
    end
  end

  defp fresh_model do
    LedgerModel.new(
      tolerance: Config.credits_overdraft_tolerance(),
      currency: Config.credits_currency()
    )
  end

  defp execute(model, command, index, tenant, history, opts) do
    guard_foreign_due!(command, tenant)
    {next, expected} = LedgerModel.apply(model, command)
    actual = issue(command, tenant)

    problems =
      result_problems(expected, actual) ++
        model_problems(next) ++
        wallet_problems(next, tenant) ++
        conservation_problems(next, tenant) ++
        attribution_problems(next, tenant) ++
        expiry_problems(next, command, tenant) ++
        step_lot_problems(next)

    if problems != [] do
      context = %{
        problems: problems,
        model: next,
        step: index,
        command: command,
        tenant: tenant,
        history: history,
        opts: opts
      }

      # A reordered ledger is not an arithmetic disagreement, and reporting it
      # as one would bury a separate, worse defect (L20) inside a false
      # arithmetic failure. The history is abandoned as inconclusive, counted,
      # and proved on its own by the named clock test in `credits_model_test`.
      case clock_step(tenant, next) do
        {:clock_step, stamps} -> throw({:inconclusive, Map.put(context, :stamps, stamps)})
        :ok -> fail!(context)
      end
    end

    next
  end

  # Did the ledger's own `(inserted_at, id)` order stop being the order it wrote
  # in? The rows carry exactly the amounts the model wrote, in a different
  # sequence: an arithmetic bug changes values, and only a reordering leaves the
  # multiset intact while the list differs.
  #
  # `inserted_at` is stamped from `DateTime.utc_now()` inside `apply_entry/3`
  # (`ledger.ex:452`), which is the host's wall clock and is not monotonic. When
  # it steps backwards, every query that orders by it is wrong, including
  # `remaining_on_grant/3` (`ledger.ex:345`), which is what decides how much of a
  # promotional grant is left. Finding L20.
  defp clock_step(tenant, model) do
    rows =
      Connections.repo().all(
        from(t in scope(tenant),
          order_by: [asc: t.inserted_at, asc: t.id],
          select: {t.amount, t.held_delta, t.balance_after, t.inserted_at}
        )
      )

    written = Enum.map(model.entries, &{&1.amount, &1.held_delta, &1.balance_after})
    stored = Enum.map(rows, fn {amount, held, after_, _at} -> {amount, held, after_} end)

    if stored != written and Enum.sort(stored) == Enum.sort(written) do
      {:clock_step, Enum.map(rows, fn {_a, _h, _b, at} -> at end)}
    else
      :ok
    end
  end

  @doc """
  The histories this OS process abandoned because the wall clock the ledger
  stamps `inserted_at` from stepped backwards mid-history (finding L20).

  Never empty by accident: a run that reports none says so, and a run that
  reports some is telling you its property covered fewer histories than it
  asked for.
  """
  @spec clock_steps() :: [map()]
  def clock_steps, do: :persistent_term.get({__MODULE__, :clock_steps}, [])

  defp record_clock_step(info) do
    summary = Map.take(info, [:tenant, :step, :problems, :stamps])
    :persistent_term.put({__MODULE__, :clock_steps}, [summary | clock_steps()])
    :ok
  end

  # -- issuing ----------------------------------------------------------------

  defp issue({:grant, reference, amount, category, expires_at}, tenant) do
    opts = [reference: scoped(tenant, reference), category: category]
    opts = if expires_at, do: [{:expires_at, expires_at} | opts], else: opts
    normalise(Credits.grant_with_status(tenant, amount, opts))
  end

  defp issue({:hold, reference, amount}, tenant),
    do: normalise(Credits.hold(tenant, amount, scoped(tenant, reference)))

  defp issue({:settle, reference, actual}, tenant),
    do: normalise(Credits.settle(scoped(tenant, reference), actual))

  defp issue({:release, reference}, tenant),
    do: normalise(Credits.release(scoped(tenant, reference)))

  defp issue({:debit, reference, amount}, tenant),
    do: normalise(Credits.debit(tenant, amount, scoped(tenant, reference)))

  defp issue({:reverse, reference, amount}, tenant),
    do: normalise(Credits.reverse(tenant, amount, scoped(tenant, reference)))

  defp issue({:expire_due, now}, _tenant), do: normalise(Credits.expire_due(now))

  # Every reference carries its tenant, because the `(kind, reference)` unique
  # index is global rather than per tenant (`migration.ex:288-293`, finding L3):
  # two histories reusing "g1" would collide on the index instead of on the
  # in-transaction lookup, and the second would see a raw changeset error that
  # has nothing to do with what it was testing.
  defp scoped(tenant, reference), do: tenant <> ":" <> reference

  defp unscoped(_tenant, nil), do: nil
  defp unscoped(tenant, reference), do: String.replace_prefix(reference, tenant <> ":", "")

  defp normalise({:ok, %CreditTransaction{}}), do: :ok
  defp normalise({:ok, %CreditTransaction{}, status}), do: {:ok, status}
  defp normalise({:ok, count}) when is_integer(count), do: {:ok, count}
  defp normalise({:error, reason}) when is_atom(reason), do: {:error, reason}

  defp normalise({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:changeset, inspect(changeset.errors)}}

  # -- per-step comparisons ---------------------------------------------------

  defp result_problems(same, same), do: []

  defp result_problems(expected, actual),
    do: ["V7 return value: model #{inspect(expected)} vs ledger #{inspect(actual)}"]

  defp model_problems(model) do
    for {invariant, problem} <- LedgerModel.self_check(model),
        do: "model self-check #{invariant}: #{problem}"
  end

  defp wallet_problems(model, tenant) do
    expected = LedgerModel.wallet(model)
    actual = Credits.balance(tenant)

    if expected == actual,
      do: [],
      else: ["V7 balance/1: model #{inspect(expected)} vs ledger #{inspect(actual)}"]
  end

  defp conservation_problems(model, tenant) do
    repo = Connections.repo()

    case repo.get_by(CreditBalance, tenant_key: tenant) do
      nil ->
        # `locked_row/2` (`ledger.ex:410-429`) creates the row on the first write
        # and even on a refusal that reached it, so its absence only means
        # nothing has been written at all.
        if model.entries == [],
          do: [],
          else: ["no balance row after #{length(model.entries)} entries"]

      row ->
        Enum.reject(
          [
            v1(repo, tenant, row),
            v2(repo, tenant, row),
            v3(row),
            v4(repo, tenant, row),
            v5(repo, tenant),
            v6(repo, tenant, model)
          ],
          &is_nil/1
        )
    end
  end

  # V1 conservation of balance.
  defp v1(repo, tenant, row) do
    sum = total(repo, scope(tenant), :amount)
    if sum == row.balance, do: nil, else: "V1: sum(amount) #{sum} != balance #{row.balance}"
  end

  # V2 conservation of held, both ways round: every row's `held_delta`, and the
  # reservations of the holds that are still open.
  defp v2(repo, tenant, row) do
    deltas = total(repo, scope(tenant), :held_delta)
    open_query = from(t in scope(tenant), where: t.kind == ^:hold and t.status == ^:pending)
    open = total(repo, open_query, :held_delta)

    cond do
      deltas != row.held -> "V2: sum(held_delta) #{deltas} != held #{row.held}"
      open != row.held -> "V2: open holds #{open} != held #{row.held}"
      true -> nil
    end
  end

  # V3 promotional bound (`ledger.ex:439-444`).
  defp v3(row) do
    if row.promotional >= 0 and row.promotional <= max(row.balance, 0),
      do: nil,
      else: "V3: promotional #{row.promotional} outside 0..max(#{row.balance}, 0)"
  end

  # V4 snapshot agreement: the newest row's three snapshot columns are the
  # balance row, because `apply_entry/3` writes both in one transaction
  # (`ledger.ex:445-468`).
  defp v4(repo, tenant, row) do
    newest =
      repo.one(from(t in scope(tenant), order_by: [desc: t.inserted_at, desc: t.id], limit: 1))

    cond do
      is_nil(newest) ->
        nil

      newest.balance_after != row.balance ->
        "V4: balance_after #{newest.balance_after} != #{row.balance}"

      newest.held_after != row.held ->
        "V4: held_after #{newest.held_after} != #{row.held}"

      newest.promotional_after != row.promotional ->
        "V4: promotional_after #{newest.promotional_after} != #{row.promotional}"

      true ->
        nil
    end
  end

  # V5 reference uniqueness per kind (`migration.ex:288-293`).
  defp v5(repo, tenant) do
    duplicates =
      repo.all(
        from(t in scope(tenant),
          where: not is_nil(t.reference),
          group_by: [t.kind, t.reference],
          having: count(t.id) > 1,
          select: {t.kind, t.reference}
        )
      )

    if duplicates == [], do: nil, else: "V5: repeated references #{inspect(duplicates)}"
  end

  # V6 hold closure.
  defp v6(repo, tenant, model) do
    repo.all(
      from(t in scope(tenant),
        where: t.kind == ^:hold,
        select: {t.reference, t.status, t.settled_amount}
      )
    )
    |> Enum.find_value(fn {reference, status, settled} ->
      hold_problem(model, unscoped(tenant, reference), status, settled)
    end)
  end

  defp hold_problem(model, reference, status, settled) do
    expected = Map.get(model.holds, reference)

    cond do
      status not in [:pending, :settled, :released] ->
        "V6: #{reference} status #{status}"

      is_nil(expected) ->
        "V6: #{reference} is in the ledger but not in the model"

      expected.status != status ->
        "V6: #{reference} is #{status}, model says #{expected.status}"

      status == :settled and is_nil(settled) ->
        "V6: settled #{reference} has no settled_amount"

      status == :settled and settled != expected.settled_amount ->
        "V6: #{reference} settled_amount"

      true ->
        nil
    end
  end

  # The model's per-grant remainders against `AuroraMeter.Credits.Promotions`,
  # which the model is forbidden to call. This is the comparison that makes the
  # attribution fold provable rather than assumed: it reproduces
  # `Ledger.remaining_on_grant/3` (`ledger.ex:340-349`) exactly, with `repo.all`
  # in place of `repo.stream` because the executor holds no transaction.
  defp attribution_problems(model, tenant) do
    repo = Connections.repo()
    ids = grant_ids(repo, tenant)

    if map_size(ids) == 0 do
      []
    else
      entries =
        repo.all(
          from(t in scope(tenant),
            where: t.amount < 0 or (t.kind == ^:grant and t.category == ^:promotional),
            order_by: [asc: t.inserted_at, asc: t.id]
          )
        )

      for {reference, id} <- ids,
          actual = Promotions.remaining(entries, id),
          expected = LedgerModel.remaining(model, reference),
          actual != expected,
          do: "V7 attribution: #{reference} model #{expected} vs Promotions #{actual}"
    end
  end

  defp grant_ids(repo, tenant) do
    repo.all(
      from(t in scope(tenant),
        where: t.kind == ^:grant and t.category == ^:promotional,
        select: {t.reference, t.id}
      )
    )
    |> Map.new(fn {reference, id} -> {unscoped(tenant, reference), id} end)
  end

  # After an `expire_due` the ledger's own account of what it took is in the
  # entry metadata (`ledger.ex:313-318`), so the model's predicted expiry is
  # compared against that rather than only against the resulting balance.
  defp expiry_problems(model, {:expire_due, _now}, tenant) do
    ledger =
      Connections.repo().all(
        from(t in scope(tenant), where: t.kind == ^:expire, select: t.metadata)
      )
      |> Enum.map(&{unscoped(tenant, &1["grant_reference"]), &1["expired_amount"]})
      |> Enum.sort()

    predicted =
      model.entries
      |> Enum.filter(&(&1.kind == :expire))
      |> Enum.map(&{&1.grant_key, -&1.amount})
      |> Enum.sort()

    if ledger == predicted,
      do: [],
      else: ["V7 expiry: model #{inspect(predicted)} vs ledger #{inspect(ledger)}"]
  end

  defp expiry_problems(_model, _command, _tenant), do: []

  defp step_lot_problems(model) do
    if lot_view_per_step?() do
      for problem <- model |> LedgerModel.lot_view() |> LedgerModel.v8_problems(),
          do: "V8 (per step): " <> problem
    else
      []
    end
  end

  @doc """
  The raw conservation aggregates for `tenant`, so a named property can assert
  its own law directly at the end of a history rather than only through the
  per-step comparison. Needs a checked-out connection.
  """
  @spec aggregates(String.t()) :: map()
  def aggregates(tenant) do
    repo = Connections.repo()
    open = from(t in scope(tenant), where: t.kind == ^:hold and t.status == ^:pending)

    %{
      row: repo.get_by(CreditBalance, tenant_key: tenant),
      amount_sum: total(repo, scope(tenant), :amount),
      held_delta_sum: total(repo, scope(tenant), :held_delta),
      open_holds_sum: total(repo, open, :held_delta),
      newest:
        repo.one(from(t in scope(tenant), order_by: [desc: t.inserted_at, desc: t.id], limit: 1)),
      duplicate_references:
        repo.all(
          from(t in scope(tenant),
            where: not is_nil(t.reference),
            group_by: [t.kind, t.reference],
            having: count(t.id) > 1,
            select: {t.kind, t.reference}
          )
        )
    }
  end

  defp scope(tenant), do: from(t in CreditTransaction, where: t.tenant_key == ^tenant)

  # `sum(bigint)` is `numeric` in Postgres, which Ecto hands back as a Decimal;
  # the cast keeps every figure in this module an integer, as the ledger's are.
  defp total(repo, query, :amount),
    do: repo.one(from(t in query, select: fragment("coalesce(sum(?), 0)::bigint", t.amount)))

  defp total(repo, query, :held_delta),
    do: repo.one(from(t in query, select: fragment("coalesce(sum(?), 0)::bigint", t.held_delta)))

  # -- global-state guard -----------------------------------------------------

  defp guard_foreign_due!({:expire_due, now}, tenant) do
    truncated = DateTime.truncate(now, :second)

    count =
      Connections.repo().one(
        from(t in CreditTransaction,
          where:
            t.tenant_key != ^tenant and t.kind == ^:grant and t.category == ^:promotional and
              not is_nil(t.expires_at) and t.expires_at <= ^truncated and is_nil(t.expired_at),
          select: count(t.id)
        )
      )

    if count > 0 do
      raise ExUnit.AssertionError,
        message: """
        #{count} committed promotional grant(s) outside #{tenant} are due at #{truncated}.
        `Credits.expire_due/1` is not tenant scoped (`ledger.ex:251-259`), so it would expire \
        them too and the count this history compares would be inflated by work it did not do. \
        Remove the leftover rows (AuroraMeter.Test.Connections.cleanup!/1) and run again.\
        """
    end

    :ok
  end

  defp guard_foreign_due!(_command, _tenant), do: :ok

  # -- V8 and the L1 leak -----------------------------------------------------

  defp assert_v8!(view, model, tenant, history, opts) do
    case LedgerModel.v8_problems(view) do
      [] ->
        :ok

      problems ->
        fail!(%{
          problems: Enum.map(problems, &("V8: " <> &1)),
          model: model,
          step: :end_of_history,
          command: nil,
          tenant: tenant,
          history: history,
          opts: opts
        })
    end
  end

  # One JSON line per history when `AURORA_LEAK_REPORT` names a file: what the
  # flat ledger still calls spendable that the lot design has written off. The
  # evidence quantifies L1 from these.
  defp report_leak(view, tenant, steps) do
    case System.get_env("AURORA_LEAK_REPORT") do
      nil ->
        :ok

      "" ->
        :ok

      path ->
        File.mkdir_p!(Path.dirname(path))

        line =
          Jason.encode!(%{
            "tenant" => tenant,
            "steps" => steps,
            "leak" => view.leak,
            "l1" => view.released_expired,
            "reserved_at_expiry" => view.expired_with_reservation,
            "expired" => view.expired,
            "debt" => view.debt,
            "lot_available" => view.available
          })

        File.write!(path, line <> "\n", [:append])
    end
  end

  # -- saving a counterexample ------------------------------------------------

  # `:save` is false when a saved seed is being replayed: a replay that fails on
  # purpose (a counterexample kept until its fixing unit lands) must not write a
  # near-duplicate of itself into the seed directory on every run.
  defp fail!(context) do
    path =
      if Keyword.get(context.opts, :save, true),
        do: save_seed(context),
        else: "(not saved: this run is a replay)"

    raise ExUnit.AssertionError,
      message: """
      the ledger and the model disagree at step #{inspect(context.step)} of \
      #{length(context.history)}.

      #{Enum.map_join(context.problems, "\n", &("  - " <> &1))}

      tenant:  #{inspect(context.tenant)}
      command: #{inspect(context.command)}
      saved:   #{path}

      Replay it with `mix test test/aurora_meter/credits_regressions_test.exs`, which runs every \
      file in #{@seed_dir} with StreamData out of the picture.\
      """
  end

  @doc """
  Writes one counterexample to `test/regressions/seeds/` as a literal term and
  returns the path.

  The file name is fixed for the whole of one OS process, so StreamData's
  shrinking overwrites it and the file left behind holds the **smallest**
  failing history rather than the first one seen.
  """
  @spec save_seed(map()) :: String.t()
  def save_seed(context) do
    seed = Keyword.get(context.opts, :seed, 0)
    label = Keyword.get(context.opts, :label, "counterexample")
    path = Path.join(@seed_dir, "i10-#{run_stamp()}-#{seed}-#{slug(label)}.exs")

    term = %{
      invariant: "I10",
      name: "seed for I10: " <> label,
      seed: seed,
      elixir: System.version(),
      otp: System.otp_release(),
      tolerance: context.model.tolerance,
      base_instant: @base,
      failed_at_step: context.step,
      problems: context.problems,
      expected: LedgerModel.projections(context.model),
      # A freshly saved counterexample is a disagreement nobody has classified
      # yet, and it says so. Whoever classifies it either names the unit that
      # fixes it (leaving `:disagreement`, so the file keeps failing until that
      # unit lands) or, if the model was the thing that was wrong, fixes the
      # model and flips this to `:agreement` in the same change.
      expect: {:disagreement, "unclassified"},
      # What the database actually held at the failing step, so the file
      # explains itself without a rerun. `inserted_at` is included because the
      # ledger orders its own audit trail by it (`ledger.ex:345`) and it is
      # stamped from the application clock (`:452`).
      observed: observed_rows(context.tenant),
      history: context.history
    }

    File.mkdir_p!(@seed_dir)
    File.write!(path, inspect(term, limit: :infinity, printable_limit: :infinity, pretty: true))
    path
  end

  # One file per property, not one per process: two properties failing in the
  # same run must not overwrite each other's counterexample.
  defp slug(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp observed_rows(nil), do: []

  defp observed_rows(tenant) do
    repo = Connections.repo()

    rows =
      repo.all(
        from(t in scope(tenant),
          order_by: [asc: t.inserted_at, asc: t.id],
          select: {t.kind, t.reference, t.amount, t.held_delta, t.balance_after, t.inserted_at}
        )
      )

    %{
      # A plain map, not the schema struct: the file has to stay a literal term
      # that `Code.eval_file/1` can read back without the schema being loaded.
      balance_row:
        case repo.get_by(CreditBalance, tenant_key: tenant) do
          nil -> nil
          row -> Map.take(row, [:tenant_key, :balance, :held, :promotional, :currency])
        end,
      transactions:
        Enum.map(rows, fn {kind, reference, amount, held_delta, balance_after, at} ->
          %{
            kind: kind,
            reference: unscoped(tenant, reference),
            amount: amount,
            held_delta: held_delta,
            balance_after: balance_after,
            inserted_at: at
          }
        end)
    }
  rescue
    _error -> :unavailable
  end

  defp run_stamp do
    case :persistent_term.get({__MODULE__, :stamp}, nil) do
      nil ->
        stamp =
          DateTime.utc_now()
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601(:basic)
          |> String.replace("Z", "")

        :persistent_term.put({__MODULE__, :stamp}, stamp)
        stamp

      stamp ->
        stamp
    end
  end
end
