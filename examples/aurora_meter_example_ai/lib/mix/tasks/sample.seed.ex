defmodule Mix.Tasks.Sample.Seed do
  @shortdoc "Seeds two organisations, four users, three credit lots and some history"

  @moduledoc """
  Seeds the sample so that every page has something on it the first time you
  open it.

      mix sample.seed

  It creates:

    * **acme**, on the `:free` plan, with no credit at all. Open `/generate` as
      an acme user to watch a hard quota refuse the sixth image, and to watch a
      wallet with no money refuse a text generation.
    * **globex**, on the `:studio` plan, with **three** credit lots, which is
      the point of the number three. Two are promotional and expire on
      different days, one is paid and never expires. Spend draws promotional
      first, earliest expiry first, then the paid lot, and `/ops` shows the
      order and the trail.
    * two users in each organisation, one owner and one member. The owner sees
      `/ops` and `/dev/tools`; the member does not.
    * a fortnight of historical generations for globex, so the spend chart has
      bars on first load rather than one.

  Every email ends `@example.com` and every password is printed below. There is
  nothing here worth protecting and nothing here that is anybody's real data.

  Run it as often as you like: it is idempotent by organisation slug and by
  grant reference.
  """
  use Mix.Task

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Accounts
  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Orgs
  alias AuroraMeterExampleAi.Repo

  @password "sample password!"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    acme = org!("acme", "Acme Design")
    globex = org!("globex", "Globex Studio")

    # Before anything is granted. See `lot_engine/1`.
    Enum.each([acme, globex], &lot_engine/1)

    AuroraMeter.subscribe(acme, :free)
    AuroraMeter.subscribe(globex, :studio)

    acme_owner = user!("owner@acme.example.com", acme, "owner")
    user!("member@acme.example.com", acme, "member")
    globex_owner = user!("owner@globex.example.com", globex, "owner")
    user!("member@globex.example.com", globex, "member")

    grants(globex)

    # The `:studio` plan declares `recurring_credits :monthly_allowance`. It is
    # granted by this scan, once per tenant, entitlement, plan version and
    # billing period. A real application runs it from a scheduler (there is an
    # Oban worker for it); the sample runs it here so the first page a reader
    # opens already has the allowance on it.
    {:ok, recurrences} = AuroraMeter.Credits.Recurrences.run(tenant: globex)
    Mix.shell().info("  recurring allowance: #{inspect(recurrences.counts)}")

    history(Scope.for_user(globex_owner))

    # **Flush before this process exits.** Buffered usage (`:images` here) lives
    # in ETS and is written to the database by the flusher on an interval.
    # `mix sample.seed` is a short-lived VM: without this line the seeded image
    # usage is lost when it stops, the server starts with an empty counter, and
    # `/generate` shows `0 / 200` images for an organisation that has used
    # three. That is documented behaviour rather than a defect (everything not
    # in an acknowledged flush batch can be lost with the VM), and it is the
    # reason `:tokens` is an events-source feature and `:images` is not: the
    # token figure survived this and the image figure did not.
    {:ok, _flushed} = AuroraMeter.Flusher.flush()

    Mix.shell().info("""

    Seeded.

      acme   (free)   #{Orgs.get_org_by_slug("acme").api_key}
      globex (studio) #{Orgs.get_org_by_slug("globex").api_key}

    Log in at /users/log-in with any of these and the password "#{@password}":

      owner@acme.example.com      sees /ops and /dev/tools
      member@acme.example.com     does not
      owner@globex.example.com    sees /ops and /dev/tools
      member@globex.example.com   does not

    globex holds #{Credits.Money.format(Credits.available(globex))} across
    #{length(Credits.Lots.list(globex, states: :all))} lots: two promotional with
    different expiry dates, one paid, and the studio plan's recurring allowance.
    Spend draws them in that order and /ops shows the trail.

    acme holds nothing, on purpose: it is the organisation that gets refused.
    """)

    _ = acme_owner
  end

  # ---------------------------------------------------------------------------
  # READ THIS BEFORE COPYING IT.
  #
  # `AuroraMeter.Credits.Ledger.enable_lots!/1` is **not public API**. It is not
  # on the `AuroraMeter.Credits` facade and it is not in the documentation as
  # something a host calls.
  #
  # It is here because, in this release, a brand new installation has no other
  # way to reach the credit lot engine at all. `lots_enabled_at` is null on
  # every new wallet, the documented route to set it is
  # `mix aurora_meter.credits.migrate_lots`, and that task's real cutover is
  # refused ("the cutover is refused (X250)") because the refund path is not
  # lot aware yet. A wallet left on the legacy engine has no lots, no allocation
  # trail, `debt` and `expired` permanently zero, and the plan DSL's
  # `recurring_credits` grants nothing, because the recurrence scan only looks
  # at wallets where `lots_enabled_at` is set.
  #
  # So this one line is the difference between a sample that can show the
  # documented credit priority (promotional before paid, earliest expiry first)
  # and one whose operations page shows two empty tables. It is fenced into its
  # own function, with this comment, so that nobody copies it without reading
  # why it is here. It is reported against the library rather than worked
  # around quietly, and when there is a public way to start a new wallet on the
  # allocator, this function becomes that call and nothing else changes.
  #
  # It refuses a wallet that already has ledger rows, which is exactly right and
  # is why it runs before the first grant.
  defp lot_engine(org) do
    AuroraMeter.Credits.Ledger.enable_lots!(AuroraMeterExampleAi.Tenancy.to_key(org))
    Mix.shell().info("  #{org.slug}: credit lot engine enabled")
  rescue
    ArgumentError ->
      Mix.shell().info(
        "  #{org.slug}: already has ledger history, left on whichever engine it is on"
      )
  end

  defp org!(slug, name) do
    case Orgs.get_org_by_slug(slug) do
      nil ->
        {:ok, org} = Orgs.create_org(%{slug: slug, name: name})
        org

      org ->
        org
    end
  end

  defp user!(email, org, role) do
    user =
      case Repo.get_by(Accounts.User, email: email) do
        nil ->
          {:ok, user} = Accounts.register_user(%{email: email})
          user

        user ->
          user
      end

    # Confirmed and with a password, so the sample can be logged into without
    # going through the mailbox. The generated authentication is magic link
    # first; a password is set here only so that a reader who just wants to see
    # the metering does not have to learn the login flow first.
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    {:ok, {user, _}} = Accounts.update_user_password(user, %{password: @password})

    user
    |> Accounts.User.org_changeset(%{org_id: org.id, role: role})
    |> Repo.update!()
  end

  # Three lots, and their order is the lesson. A spend takes promotional before
  # paid, and within promotional the one that expires soonest, because credit
  # that is about to be lost is worth spending first.
  defp grants(globex) do
    now = DateTime.utc_now()

    Credits.grant(globex, 3_000_000,
      reference: "synthetic:seed:globex:promo-early",
      category: :promotional,
      expires_at: DateTime.add(now, 7, :day) |> DateTime.truncate(:second),
      metadata: %{"why" => "seeded by mix sample.seed, no payment"},
      source: %{"promotion" => "welcome"}
    )

    Credits.grant(globex, 4_000_000,
      reference: "synthetic:seed:globex:promo-late",
      category: :promotional,
      expires_at: DateTime.add(now, 60, :day) |> DateTime.truncate(:second),
      metadata: %{"why" => "seeded by mix sample.seed, no payment"},
      source: %{"promotion" => "second-month"}
    )

    Credits.grant(globex, 20_000_000,
      reference: "synthetic:seed:globex",
      category: :paid,
      metadata: %{"why" => "seeded by mix sample.seed, no payment was taken"},
      source: %{"promotion" => nil}
    )
  end

  # Twelve **real** generations, through the same `Generations.create/3` the
  # browser calls. They take real holds, do the simulated work, record real
  # durable events, stage real outbox items and settle against the three lots
  # in the documented order, so `/ops` has something true on it the first time
  # it is opened.
  #
  # The build plan for this unit asked for backdated history so the spend chart
  # would have a fortnight of bars. It does not, and that is deliberate: a
  # backdated generation means a backdated ledger entry, and putting a fiction
  # into the ledger is the one thing the operations page must never show. The
  # chart has one bar, today, and the rest of the buckets draw as the baseline
  # they are.
  defp history(%Scope{} = scope) do
    if Repo.aggregate(Generation, :count) == 0 do
      Enum.each(1..12, fn n ->
        model = if rem(n, 3) == 0, do: "nimbus-1", else: "nimbus-1-mini"
        kind = if rem(n, 4) == 0, do: "image", else: "text"

        AuroraMeterExampleAi.Generations.create(
          scope,
          %{"kind" => kind, "prompt" => "seeded prompt number #{n}", "model" => model},
          Ecto.UUID.generate()
        )
      end)
    end
  end
end
