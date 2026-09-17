# Example: a team SaaS with tiers

**The product.** Bramble is a project-management app sold to teams. Three
tiers. Some things are switched off on the cheap tier, some things are capped,
and every tier allows a certain number of people.

This example covers switches (`feature`), plan values (`feature :seats, 5`) and
hard caps (`limit … :hard`). No money changes hands inside Aurora Meter here:
Bramble charges a flat monthly price, and the only job is deciding who may do
what.

## 1. Write the plans down

```elixir
defmodule Bramble.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    feature :seats, 3
    feature :pdf_export, false
    feature :audit_log, false
    limit :projects, 2, :hard
    limit :file_uploads, 100, :hard
  end

  plan :team do
    price 4_900                    # $49.00 per month, in cents
    feature :seats, 20
    feature :pdf_export, true
    feature :audit_log, false
    limit :projects, 50, :hard
    limit :file_uploads, 10_000, :hard
  end

  plan :business do
    price 19_900                   # $199.00
    feature :seats, 200
    feature :pdf_export, true
    feature :audit_log, true
    limit :projects, 1_000, :hard
    limit :file_uploads, 250_000, :hard
  end
end
```

Three things to notice.

**`price` is in cents**, not dollars and not micro-dollars. It is a label for
your pricing page; Aurora Meter never charges it. (Micro-dollars are only used
by the credit ledger.)

**This module is checked when it compiles.** A duplicate feature, a negative
limit or a misspelled mode raises at compile time, not at 3am in production.

**`:seats` is a `feature`, not a `limit`.** That is deliberate, and the next
section explains why: it is the part people get wrong.

## 2. Seats: a number, not a counter

A `limit` counts *events that happened*. Seats are not events. A person joins,
a person leaves, and the number goes up and down. A counter only ever goes up
within a period.

So `:seats` is a plan **value** you read, and you compare it against your own
count of users:

```elixir
defmodule Bramble.Members do
  import Ecto.Query
  alias Bramble.{Member, Repo}

  def can_invite?(org) do
    allowed = AuroraMeter.feature_value(org, :seats, 1)
    used = Repo.aggregate(from(m in Member, where: m.org_id == ^org.id), :count)
    used < allowed
  end
end
```

`feature_value/3`'s third argument is the fallback used when the plan says
nothing about that feature. Choose it carefully: `1` is a safe floor, `0` locks
everyone out, and `999` gives the shop away.

**Rule of thumb.** If removing one makes the number go down, it is a
`feature` value. If it can only ever go up until the month ends, it is a
`limit` or a `metered` feature.

## 3. Switches: on or off

```elixir
AuroraMeter.check(org, :pdf_export)
# :ok                          on :team and :business
# {:error, :not_entitled}      on :free
```

In a controller, the shape you want almost always is:

```elixir
defmodule BrambleWeb.ExportController do
  use BrambleWeb, :controller

  def pdf(conn, %{"project_id" => id}) do
    case AuroraMeter.check(conn.assigns.current_org, :pdf_export) do
      :ok ->
        render(conn, :pdf, pdf: Bramble.Exports.render_pdf(id))

      {:error, :not_entitled} ->
        conn
        |> put_status(:payment_required)
        |> json(%{error: "PDF export is available on Team and Business."})
    end
  end
end
```

For templates, `allowed?/2` reads better than matching on a tuple:

```heex
<.link :if={AuroraMeter.allowed?(@org, :pdf_export)} href={~p"/projects/#{@project}/pdf"}>
  Download PDF
</.link>
```

There are two questions here that look the same and are not:

```elixir
AuroraMeter.entitled?(org, :file_uploads)   # does the plan grant this at all?
AuroraMeter.allowed?(org, :file_uploads)    # ...and is there room right now?
```

A team on `:free` that has used all 100 uploads is **entitled** (the plan gives
them uploads) but not **allowed** (they are out). Use `entitled?/2` to decide
whether to show a feature at all, and `allowed?/2` to decide whether this click
works. Showing an upgrade prompt for something their plan already includes is
the mistake this distinction prevents.

## 4. Hard caps: the wall

```elixir
AuroraMeter.check(org, :projects)
# :ok until 2 projects on :free, then {:error, :limit_exceeded}
```

Here is the trap. This code is wrong:

```elixir
# WRONG: two requests can both pass
with :ok <- AuroraMeter.check(org, :projects) do
  {:ok, project} = Bramble.Projects.create(org, attrs)
  AuroraMeter.track(org, :projects)
  {:ok, project}
end
```

Two people click "New project" at the same moment on a free plan that has one
project. Both read 1 of 2. Both pass. Both create. The team now has three
projects on a plan that allows two, and nothing will ever notice.

`with_quota/4` closes it by reserving the count and the permission together:

```elixir
defmodule Bramble.Projects do
  def create(org, attrs) do
    AuroraMeter.with_quota(org, :projects, fn ->
      %Project{} |> Project.changeset(attrs) |> Repo.insert!()
    end)
  end
end

Bramble.Projects.create(org, %{name: "Rebrand"})
# {:ok, %Project{}}
# {:error, :limit_exceeded}
```

Under any amount of concurrency, a cap of 2 admits exactly 2.

**The reservation is the usage.** `with_quota/4` increments the counter itself, so
do not also call `track/3`, or every project counts twice.

If the function raises, the reservation is released before the error is
re-raised, so a failed insert does not burn a slot. The same is true if it
*exits* (a database checkout timeout, for instance), which is the common way
this kind of work fails.

For more than one at a time, pass a quantity:

```elixir
AuroraMeter.with_quota(org, :file_uploads, length(files), fn ->
  Enum.map(files, &store!/1)
end)
```

That is all-or-nothing: 12 files against 10 remaining refuses all 12 rather
than storing 10 and failing.

## 5. Deleting things

A project is deleted. Does the count go down?

**No, and that is on purpose.** The counter measures *projects created this
period*, not *projects that exist*. If deleting gave a slot back, a free team
could create, delete, create, delete, and have unlimited projects, each one a
real row in your database for as long as they cared to keep it.

If what you actually want to cap is *how many exist at once*, that is the seats
pattern from section 2: a `feature` value you compare against a live `COUNT(*)`.
Decide which of the two you mean before you write the plan. Both are legitimate;
they are different products.

## 6. Changing plan

```elixir
AuroraMeter.subscribe(org, :team)
```

That is the whole upgrade, as far as metering goes. It takes effect
immediately: the caps are read from the plan on every check, so a team that was
blocked at 2 projects can create the third the instant they upgrade.

**Usage is not reset by a plan change.** A team that used 40 uploads on `:free`
still has 40 used when they move to `:team`. They now have 10,000 to play
with, so it makes no practical difference, and resetting would let anyone
refill by switching plan and switching back.

### When a subscription lapses

If you are using the Pro package, subscriptions are synced from Stripe and
carry a status. A plan is granted only while that status is `active`,
`trialing` or `past_due`. Anything else (`canceled`, `unpaid`, `incomplete`)
falls back to the configured `:default_plan`:

```elixir
config :aurora_meter, default_plan: :free
```

So a cancellation revokes access on its own. You do not write a downgrade job,
and there is no window where a cancelled customer keeps Business features
because your nightly sweep has not run yet.

## 7. The upgrade prompt that knows what to say

`quota/2` returns everything a dashboard card needs in one call:

```elixir
AuroraMeter.quota(org, :projects)
# %{feature: :projects, kind: :hard, used: 2, limit: 2, included: 2,
#   remaining: 0, overage: 0, percent: 100, enabled: true, unit_price: nil,
#   period: %{start: ~U[...], end: ~U[...], source: :calendar}}
```

Which turns a generic "upgrade!" into something a customer can act on:

```heex
<div :let={q} :if={@quota.kind == :hard and @quota.remaining == 0}>
  <p>
    You have used all <%= @quota.limit %> projects on the Free plan.
    They reset on <%= Calendar.strftime(@quota.period.end, "%e %B") %>.
  </p>
  <.link href={~p"/billing/upgrade"}>Team gives you 50 →</.link>
</div>
```

`remaining/2` on its own is there when that is genuinely all you need:

```elixir
AuroraMeter.remaining(org, :projects)     # => 0
AuroraMeter.remaining(org, :ai_summaries) # => :unlimited  (metered or counter)
```

Note that `:unlimited` is an atom, not a big number. Code that does
`remaining(org, f) > 0` will raise on it in a future Elixir and silently
misbehave today, so match on it.

## 8. Features you have not declared

```elixir
AuroraMeter.check(org, :some_new_thing)   # => :ok
```

An undeclared feature is permissive. A half-finished feature does not lock your
customers out of the product, and in `:dev` it logs a warning so you notice
before it ships.

If you would rather a typo be loud, declare every feature on every plan, with
`feature :some_new_thing, false` on the tiers that should not have it, and the
warning stops being your only defence.

## The whole thing, end to end

```elixir
# Once, at signup
AuroraMeter.subscribe(org, :free)

# Is the button visible at all?
AuroraMeter.entitled?(org, :pdf_export)        # => false on :free

# Can this person be invited?
Bramble.Members.can_invite?(org)               # 3 seats vs COUNT(*)

# Create a project, safely, under any concurrency
Bramble.Projects.create(org, attrs)            # {:ok, _} | {:error, :limit_exceeded}

# What should the dashboard say?
AuroraMeter.quota(org, :projects)              # %{used: 2, limit: 2, percent: 100, ...}

# They paid
AuroraMeter.subscribe(org, :team)
Bramble.Projects.create(org, attrs)            # {:ok, %Project{}}
```

Next: [Allowance and overage](allowance-and-overage.md) if you want to charge
for going over, or [Showing usage](showing-usage.md) to put this on screen.
