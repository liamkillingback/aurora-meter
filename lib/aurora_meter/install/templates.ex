defmodule AuroraMeter.Install.Templates do
  @moduledoc false
  # Source templates used by `mix aurora_meter.install`. They live in code rather
  # than priv/ because the Hex package deliberately excludes priv/.

  alias AuroraMeter.Install.Options
  alias AuroraMeter.Install.Plan

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

  @doc """
  The migration body: delegate to the versioned `AuroraMeter.Migration`, naming
  both ends of the range.

  Not `up()` with no arguments, which is what this generated until build unit
  09b. An unbounded body runs to whatever version the installed package has
  reached on the day it is applied, so the same committed file produces one
  schema in the database it was written against and another in a database
  created after the next release, and a host's migration history stops being a
  record of anything (`open-findings.md` S1).

  The range comes from `AuroraMeter.Install.Plan`, which
  `mix aurora_meter.gen.migration` reads too.
  """
  @spec migration_body() :: String.t()
  def migration_body do
    [file] = Plan.files(package: :core)

    """
    def up, do: #{file.up}
    def down, do: #{file.down}
    """
  end

  @doc """
  The `feature_sources` map literal, written the way a person would write it.
  """
  @spec feature_sources(%{atom() => atom()}) :: String.t()
  def feature_sources(sources) do
    body =
      sources
      |> Enum.sort()
      |> Enum.map_join(", ", fn {feature, source} -> "#{feature}: #{inspect(source)}" end)

    "%{" <> body <> "}"
  end

  @doc """
  What the installer says when it found `undeclared_feature_policy` already set
  and left it alone.

  It says which value it kept, because an installer that keeps a value silently
  cannot be told apart from one that wrote it, and the difference is the whole
  of decision D04's upgrade path.
  """
  @spec kept_policy(atom(), String.t() | nil) :: String.t()
  def kept_policy(would_have_written, flag) do
    asked =
      if flag do
        "You passed --feature-policy #{flag}, and it was not applied. "
      else
        ""
      end

    """
    config/config.exs already sets :undeclared_feature_policy. It was kept
    exactly as written.

    #{asked}This key is the one an upgrading host tunes, so the installer only
    ever creates it and never changes it. A fresh install would have been given
    #{inspect(would_have_written)}.

    To change it, edit config/config.exs yourself. The upgrade path from an
    existing install is :warn first, then `mix aurora_meter.features` until it
    reports nothing, then :deny.
    """
  end

  @doc "What the installer says when it found `feature_sources` already set."
  @spec kept_sources(%{atom() => atom()}) :: String.t()
  def kept_sources(sources) do
    """
    config/config.exs already sets :feature_sources. It was kept exactly as
    written, and #{feature_sources(sources)} was not applied.

    A feature has exactly one reporting source, so merging two answers would be
    guessing at which one a bill should come from. Edit config/config.exs
    yourself if you meant to change it.
    """
  end

  @doc "What the installer says when it wrote `feature_sources`."
  @spec sources_notice(%{atom() => atom()}) :: String.t()
  def sources_notice(sources) do
    """
    config :aurora_meter, feature_sources: #{feature_sources(sources)}

    A feature listed as :events is recorded durably through AuroraMeter.record/4
    and projected; AuroraMeter.track/4 raises for it, because a feature has
    exactly one reporting source and counting it twice is how a bill stops
    matching the events behind it.
    """
  end

  @doc """
  The whole `config :my_app, Oban` block, for a host that has none.

  Written as source rather than as a term so that the crontab reads the way a
  person would write it, with the worker module as an alias rather than as
  `:"Elixir.AuroraMeter.Oban.CreditExpiry"`.
  """
  @spec oban_config(module(), [{String.t(), module()}]) :: String.t()
  def oban_config(repo, entries) do
    """
    [
      repo: #{inspect(repo)},
      queues: [aurora_meter: 5],
      plugins: [{Oban.Plugins.Cron, crontab: #{crontab(entries)}}]
    ]
    """
  end

  @doc "The `Oban.Plugins.Cron` plugin literal carrying `entries`."
  @spec cron_plugin([{String.t(), module()}]) :: String.t()
  def cron_plugin(entries), do: "{Oban.Plugins.Cron, crontab: " <> crontab(entries) <> "}"

  @doc "The crontab list literal for `entries`."
  @spec crontab([{String.t(), module()}]) :: String.t()
  def crontab([]), do: "[]"

  def crontab(entries) do
    "[\n" <>
      Enum.map_join(entries, ",\n", fn {schedule, worker} ->
        "  {#{inspect(schedule)}, #{inspect(worker)}}"
      end) <> "\n]"
  end

  @doc "The startup validation line the installer adds to `Application.start/2`."
  @spec validate_call(atom()) :: String.t()
  def validate_call(otp_app) do
    """
    if Code.ensure_loaded?(AuroraMeter.Oban), do: AuroraMeter.Oban.validate!(otp_app: #{inspect(otp_app)})\
    """
  end

  @doc "The same line, as a notice, when the installer could not place it."
  @spec validate_manual(atom()) :: String.t()
  def validate_manual(otp_app) do
    """
    Add this to your Application.start/2, before the children list:

        #{validate_call(otp_app)}

    It reads configuration rather than a running Oban instance, so it works
    whether Oban starts before or after AuroraMeter. It raises
    AuroraMeter.Oban.ConfigError listing every problem it found, rather than the
    first one.
    """
  end

  @doc "What the `--oban` switch did, and what it deliberately did not do."
  @spec oban_notice([{String.t(), module()}]) :: String.t()
  def oban_notice(entries) do
    """
    Aurora Meter's Oban workers are wired in.

    #{Enum.map_join(entries, "\n", fn {schedule, worker} -> "  #{schedule}  #{inspect(worker)}" end)}

    Nothing you had already set was changed. A queue concurrency you chose, a
    schedule you chose for one of these workers, and the order of your plugins
    are all as you wrote them; only absent entries were added. Run the task
    again and it will report no changes.

    Pause any of them without a deploy:

        AuroraMeter.Operations.pause("credit_expiry:global")
        AuroraMeter.Operations.resume("credit_expiry:global")

    One case the validator cannot see: a second Oban instance with its own Cron
    plugin. If you run two, check the crontabs against each other by hand.
    """
  end

  @doc "What to do after the installer has run."
  @spec quickstart(module(), module(), module(), AuroraMeter.Install.Options.t()) :: String.t()
  def quickstart(repo, pubsub, plans, settings) do
    """
    Aurora Meter is installed.

      config :aurora_meter, repo: #{inspect(repo)}, pubsub: #{inspect(pubsub)}, plans: #{inspect(plans)}
      undeclared_feature_policy: #{inspect(settings.policy)} #{policy_gloss(settings.policy)}#{sources_line(settings.feature_sources)}
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

  defp policy_gloss(:deny), do: "(a feature no plan declares is refused, not allowed)"
  defp policy_gloss(:raise), do: "(a feature no plan declares raises)"
  defp policy_gloss(:warn), do: "(a feature no plan declares is allowed and logged)"
  defp policy_gloss(:allow), do: "(a feature no plan declares is allowed silently)"

  defp sources_line(sources) when map_size(sources) == 0, do: ""
  defp sources_line(sources), do: "\n  feature_sources: " <> feature_sources(sources)

  @doc """
  The manual steps, for when Igniter is not available.

  It prints the settings the operator actually asked for, rather than the
  defaults. A fallback that ignored `--feature-policy` would print one
  configuration while the operator had asked for another, and the host would
  copy the printed one.
  """
  @spec manual_steps(AuroraMeter.Install.Options.t() | nil) :: String.t()
  def manual_steps(settings \\ nil) do
    settings = settings || %{policy: Options.default_policy(), feature_sources: %{}}

    """

    Aurora Meter migration generated. Next:

      1. Run the migration:   mix ecto.migrate
      2. Configure it:

         config :aurora_meter,
           repo: MyApp.Repo,
           pubsub: MyApp.PubSub,
           plans: MyApp.Plans,
           undeclared_feature_policy: #{inspect(settings.policy)}#{manual_sources(settings.feature_sources)}

      3. Add it to your supervision tree, after the Repo and PubSub:

         children = [MyApp.Repo, {Phoenix.PubSub, name: MyApp.PubSub}, AuroraMeter, ...]

      4. Declare your plans in MyApp.Plans (use AuroraMeter.Plans).

    Tip: add {:igniter, "~> 0.8", only: [:dev]} and run `mix igniter.install aurora_meter`
    to have all four steps done for you. The Igniter path also takes --oban,
    --events-source and --check-support, and Igniter's own --dry-run.
    """
  end

  defp manual_sources(sources) when map_size(sources) == 0, do: ""

  defp manual_sources(sources),
    do: ",\n           feature_sources: " <> feature_sources(sources)
end
