defmodule AuroraMeter.Install.Templates do
  @moduledoc false
  # Source templates used by `mix aurora_meter.install`. They live in code rather
  # than priv/ because the Hex package deliberately excludes priv/.

  @doc "A starter plans module with a free and a pro plan."
  @spec plans_module(module()) :: String.t()
  def plans_module(module) do
    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      Aurora Meter plans. Declared at compile time and validated by the DSL.

      Hard limits block at the cap (`AuroraMeter.with_quota/4`), metered features
      count past their included allowance for billing, counters measure without
      ever blocking or billing, boolean features gate access outright and integer
      features carry a plan value for `AuroraMeter.feature_value/3`.
      See https://hexdocs.pm/aurora_meter/plans.html.
      \"\"\"
      use AuroraMeter.Plans

      plan :free do
        price 0
        limit :ai_generations, 100, :hard
        feature :priority_support, false
        feature :seats, 1
      end

      plan :pro do
        price 4_900
        metered :ai_generations, included: 10_000, unit_price: 1
        feature :priority_support, true
        feature :seats, 10
      end
    end
    """
  end

  @doc "The migration body: delegate to the versioned `AuroraMeter.Migration`."
  @spec migration_body() :: String.t()
  def migration_body do
    """
    def up, do: AuroraMeter.Migration.up()
    def down, do: AuroraMeter.Migration.down()
    """
  end

  @doc "What to do after the installer has run."
  @spec quickstart(module(), module(), module()) :: String.t()
  def quickstart(repo, pubsub, plans) do
    """
    Aurora Meter is installed.

      config :aurora_meter, repo: #{inspect(repo)}, pubsub: #{inspect(pubsub)}, plans: #{inspect(plans)}
      undeclared_feature_policy: :deny (a feature no plan declares is refused, not allowed)
      AuroraMeter added to your supervision tree
      #{inspect(plans)} created with :free and :pro plans
      migration generated (run `mix ecto.migrate`)

    Meter and gate (org is your tenant: the customer's org or account id as a
    string or integer, or your own struct via a custom AuroraMeter.Tenant):

      AuroraMeter.subscribe(org, :free)
      AuroraMeter.track(org, :ai_generations)
      AuroraMeter.with_quota(org, :ai_generations, fn -> generate() end)

    Docs: https://hexdocs.pm/aurora_meter
    """
  end

  @doc "The manual steps, for when Igniter is not available."
  @spec manual_steps() :: String.t()
  def manual_steps do
    """

    Aurora Meter migration generated. Next:

      1. Run the migration:   mix ecto.migrate
      2. Configure it:

         config :aurora_meter,
           repo: MyApp.Repo,
           pubsub: MyApp.PubSub,
           plans: MyApp.Plans,
           undeclared_feature_policy: :deny

      3. Add it to your supervision tree, after the Repo and PubSub:

         children = [MyApp.Repo, {Phoenix.PubSub, name: MyApp.PubSub}, AuroraMeter, ...]

      4. Declare your plans in MyApp.Plans (use AuroraMeter.Plans).

    Tip: add {:igniter, "~> 0.8", only: [:dev]} and run `mix igniter.install aurora_meter`
    to have all four steps done for you.
    """
  end
end
