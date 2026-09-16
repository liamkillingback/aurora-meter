# 07b: the transition state machine and the precedence table, as implemented

Build unit 07b. Every row below names the SQL predicate that decides it, what a
stale writer observes, and the test that proves it. Source:
`lib/aurora_meter/subscriptions/transitions.ex`.

## 1. States

`aurora_meter_plan_transitions.state` is the audit row, one per
`(tenant_key, ref)`. `aurora_meter_subscriptions.transition_state` is the
queryable mirror of the current transition, and the two are only ever written
inside one transaction holding the subscription row's `FOR UPDATE`.

`NULL` on the mirror means "no transition". The audit row's states are
`pending`, `applied`, `cancelled`, `failed`.

## 2. Transitions

Every predicate below is evaluated **after** `SELECT ... FOR UPDATE` on
`aurora_meter_subscriptions` for the tenant.

| From, to | Predicate | SQL that carries it | What a stale writer observes | Test |
|---|---|---|---|---|
| none to `pending` | no pending transition, or `replace: true`, or the same `ref` with identical canonical parameters | `UPDATE aurora_meter_subscriptions ... WHERE tenant_key = $1 AND (transition_state IS NULL OR transition_state <> 'pending' OR transition_ref = $ref)` | a second scheduler with the same ref gets the existing row; with a different ref and `replace: false`, `{:error, {:conflict, %{pending_ref: ...}}}`; zero rows rolls back with `{:error, {:conflict, :concurrent_schedule}}` | `test I17 schedule_transition writes the audit row and mirrors it on the subscription`; `test I16 twelve independent connections scheduling one ref produce one transition row` |
| `pending` to `pending` (idempotent) | `canonical(stored) == canonical(submitted)` over `to_plan_id`, `to_version`, `effective_at`, `confirm` | none: the stored row is returned and nothing is written | eleven of twelve concurrent callers take this branch and the telemetry counts them `result: :idempotent` | `test I17 the same ref with identical parameters returns the existing transition` |
| `pending` to `cancelled` (explicit) | `state = 'pending'` and `ref` matches | `UPDATE aurora_meter_plan_transitions SET state = 'cancelled', detail = $d WHERE tenant_key = $1 AND ref = $2 AND state = 'pending' RETURNING *` then `UPDATE aurora_meter_subscriptions SET transition_state = 'cancelled' WHERE tenant_key = $1 AND transition_ref = $2 AND transition_state = 'pending'` | a concurrent apply either wins (the cancel then returns `{:error, {:conflict, %{state: "applied"}}}`) or loses (the apply's own predicate affects zero rows and it counts a skip) | `test I17 cancel_transition moves pending to cancelled and clears the pending state`; `test I16 a cancel racing an apply yields exactly one terminal state` |
| `pending` to `cancelled` (`replaced`) | a second `schedule_transition/3` with a different ref and `replace: true` | the same statement, `detail.reason = "replaced"`, `detail.replaced_by = <new ref>` | the earlier transition is gone at the next read and the audit row says who replaced it | `test I17 a second ref with replace: true cancels the first and schedules the second` |
| `pending` to `cancelled` (`provider_override`) | a `put_subscription/1` wrote a `(plan_id, plan_version)` equal to neither the previous pair nor the scheduled target | the same statement, `detail.reason = "provider_override"`, `detail.observed = %{plan_id, plan_version}` | the transition is gone; a later `apply_due_transitions/1` applies nothing | `test I17 a provider sync to a different plan cancels the pending transition` |
| `pending` to `cancelled` (`subscription_not_entitled`) | a `put_subscription/1` wrote a status outside `Subscription.entitled_statuses/0` | the same statement, `detail.reason = "subscription_not_entitled"`, `detail.status` | as above | `test I17 a provider sync writing a non-entitled status cancels the pending transition` |
| `pending` to `applied` (local) | `state = 'pending'`, `effective_at <= now`, `confirm = 'local'` | `UPDATE aurora_meter_subscriptions SET plan_id, plan_version, plan_fingerprint, plan_effective_at = <effective_at>, transition_state = 'applied', transition_applied_at = clock_timestamp() WHERE tenant_key = $1 AND transition_ref = $ref AND transition_state = 'pending'` | zero rows affected, reported as a `skipped` count, never an error | `test I17 apply_due_transitions applies a transition whose effective_at has passed`; `test I16 twelve independent connections applying one due transition apply it once` |
| `pending` to `applied` (provider) | as above with `provider_ref IS NOT NULL` | the same statement | a provider transition with no `provider_ref` is counted `skipped` and left for 07c | `test I17 apply_due_transitions applies a provider transition once provider_ref is set` |
| `pending` to `applied` (`provider_applied_early`) | `put_subscription/1` wrote exactly the scheduled `(plan_id, plan_version)` | the audit row's `state = 'pending'` predicate plus the mirror's `transition_state = 'pending'`; the mirror also gains the target's `plan_fingerprint` and `plan_effective_at`, which the provider did not write | idempotent: a second observer finds `applied` and does nothing | `test I17 a provider sync to exactly the scheduled target applies the transition early` |
| `pending` to `failed` | the target `(plan_id, version)` resolves through neither compiled code nor `aurora_meter_plan_versions` | `UPDATE aurora_meter_plan_transitions SET state = 'failed', detail = $d WHERE id = $1 AND state = 'pending'` plus the mirror | the row stays `failed` with `detail.error`; it is never retried automatically | `test I17 a transition to a version in neither code nor snapshots is failed and not retried` |

**A transient database error never produces `failed`.** The transaction rolls
back and the row stays `pending` for the next run. Only a deterministic,
self-repeating validation failure is terminal, which is why
`AuroraMeter.Plans.get/2` returning `nil` is the only thing that reaches it.

**L17.10, and where it can actually be seen.** Under the row lock the audit row
is re-read before any update, so for every state the code itself can produce
that re-read decides first and the `transition_state = 'pending'` clause in the
subscription `UPDATE` never changes an outcome. It changes exactly one: a
mirror that already says `applied` beside an audit row that still says
`pending`, which is what a stale writer or a torn write leaves. That is
`test I17 the applier refuses a row whose mirror says applied and whose audit
row says pending`, and it is the only test in the file that negative control
`a-apply-unconditional` fails. See finding X295.

## 3. Ordering inside `put_subscription/1`

The build document numbers the status rule last. **It is tested first**, and
deliberately: a provider write that both moves the plan to the scheduled target
and ends the subscription must not apply the transition, because a tenant who is
no longer entitled has no plan to move to. Proved by
`test I17 a cancellation wins over a sync that also names the scheduled target`.

```
put_subscription(attrs)
  |
  +-- attrs name neither plan_id, plan_version nor status?  -> no read, no reaction
  |
  +-- pre-read the row (one uncached SELECT)
        |
        +-- transition_state is not 'pending'  -> plain upsert, no transaction
        |         |
        |         +-- the upsert's returned row says 'pending' after all
        |             (a schedule landed in the window)  -> react in its own
        |                                                   transaction
        |
        +-- transition_state = 'pending'  -> upsert and reaction in ONE
                                             transaction, under FOR UPDATE:
              1. status not entitled      -> cancel, "subscription_not_entitled"
              2. written pair == scheduled pair -> apply early
              3. written pair != previous pair  -> cancel, "provider_override"
              4. otherwise                      -> leave pending
```

The window in the second branch is real and is closed rather than documented
away: the upsert returns the row's current transition columns (they are outside
the replace list), so a `pending` state there means a schedule committed between
the pre-read and the upsert, and the reaction runs in its own transaction. It
costs an ordinary sync nothing, because an ordinary sync has no pending
transition and never reaches that clause.

## 4. Precedence, as implemented

| Situation | Rule | Mechanism | Owner | Test |
|---|---|---|---|---|
| Scheduled change effective before the subscription stops being entitled | applies at its boundary; the cancellation happens later on its own | nothing special | core | `test I17 a transition effective before a later cancellation applies normally` |
| Scheduled change with a non-entitled status written | the cancellation supersedes | `put_subscription/1` rule 1 | core | `test I17 a provider sync writing a non-entitled status cancels the pending transition` |
| Cancellation known in advance (`cancel_at_period_end`) with a transition at or after `current_period_end` | Pro cancels the transition when it observes the flag | `Pro.Subscriptions.sync/1` calls `cancel_transition/2` | **Pro, 07c** | not in core; `docs/plans.md` says so |
| Provider immediate change to a plan that is not the scheduled target | the provider wins now; the transition is cancelled | rule 3 | core | `test I17 a provider sync to a different plan cancels the pending transition` |
| Provider immediate change to exactly the scheduled target | applied early rather than cancelled and rescheduled | rule 2 | core | `test I17 a provider sync to exactly the scheduled target applies the transition early` |
| Provider write naming a plan id without a version | treated as an override, not an early apply | rule 2 compares the **pair** | core, and 07c must send the pair | `test I17 a provider sync naming the plan id without the version cancels rather than applies` (finding X296) |
| Provider write that changes nothing about the plan | the transition stays pending | rule 4 | core | `test I17 a provider sync that does not change the plan leaves the transition pending` |
| Two local schedules for one tenant | the later with `replace: true` cancels the earlier atomically; with `replace: false` it is refused | one transaction under the row lock | core | `test I17 a second ref with replace: true ...`, `... with replace: false returns a conflict naming the pending ref` |
| The same schedule submitted twice | idempotent by `(tenant_key, ref)` | unique index plus the canonical comparison | core | `test I17 the same ref with identical parameters returns the existing transition` |
| A stale webhook for an ended subscription | never applied at all | `Pro.Subscriptions.resurrects?/2`, unchanged | Pro, existing | core's half: `test I17 a stale sync for an ended subscription cannot revive a cancelled transition` |
| A stale webhook that would move the plan backwards | the provider is retrieved fresh before syncing | `pro/stripe.ex:133`, unchanged | Pro, existing | not in core |
| Zero-price transition | identical to any other; core never looks at a price | no special case, and two tests assert there is none | core | `test I17 no transition source names a price, so no branch can depend on one`; `test I17 a zero-price transition issues exactly the statements a priced one does` |

## 5. What core cannot observe, stated plainly

`architecture-map.md` section 8 says "cancellation at period end supersedes a
scheduled change effective after it". Core has no `cancel_at_period_end` column
and `free-pro-boundary.md` section 3 refuses to add provider concepts to it. The
**observable** equivalent is implemented here: a non-entitled status cancels a
pending transition when it is written. The **advance-notice** half is Aurora
Meter Pro's and is assigned to 07c in both this table and `docs/plans.md`.
