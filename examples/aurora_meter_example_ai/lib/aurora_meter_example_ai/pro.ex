defmodule AuroraMeterExampleAi.Pro do
  @moduledoc """
  Whether Aurora Meter Pro is in this build, and the one place that asks.

  This module is the boundary between the two profiles of this sample. It is
  the **only** file outside `lib/aurora_meter_example_ai/pro/` that names
  `AuroraMeter.Pro` at all, and `test/pro_absent_test.exs` fails the suite if a
  second one appears.

  ## How the guard works, and why it is compile time

      @available Code.ensure_loaded?(AuroraMeter.Pro)

  `Code.ensure_loaded?/1` runs while this file is being compiled, and the
  answer is baked in. That matters for three reasons:

    * `AuroraMeterExampleAiWeb.Router`'s body is macro-expanded at compile
      time, so a runtime check could not remove a route. The Pro routes are
      **absent** from the core profile's route table, not present and refusing.
    * the supervision tree's child list is one expression, and a child that is
      not in it cannot be started by accident.
    * a `Code.ensure_loaded?/1` on every render would be a code-server round
      trip on a page that draws a meter.

  ## What "absent" means, precisely

  In the core profile `AuroraMeter.Pro` is not in the dependency tree at all:
  `mix.exs` adds it only when `AURORA_SAMPLE_PRO=1`, and the two profiles have
  separate lockfiles so one cannot leak into the other's resolution. So the
  core profile has no commercial package on disk, no Stripe SDK, no Oban, no
  key, and no page that mentions any of them.

  The `/generate` page shows a "top up" affordance only when `available?/0` is
  true. In the core profile that affordance is **absent**: not disabled, not
  greyed, not a stub that explains what you would get. A disabled button that
  says "top up" is a payment UI that does not work, and build unit 09c's rule
  against a misleading payment surface applies at this boundary exactly as it
  applies inside the page.
  """

  # The single unguarded mention of `AuroraMeter.Pro` in this application, and
  # it is inside `Code.ensure_loaded?/1`, which answers `false` rather than
  # raising when the module is not there.
  @available Code.ensure_loaded?(AuroraMeter.Pro)

  @doc """
  True when this build has Aurora Meter Pro in it.

  ## Examples

      iex> is_boolean(AuroraMeterExampleAi.Pro.available?())
      true

  """
  @spec available?() :: boolean()
  def available?, do: @available

  @doc """
  The profile's name, for a page, a log line or an evidence file.

  ## Examples

      iex> AuroraMeterExampleAi.Pro.profile() in [:core, :pro]
      true

  """
  @spec profile() :: :core | :pro
  def profile, do: if(@available, do: :pro, else: :core)

  @doc """
  Raises with a message a reader can act on when Pro is absent.

  Used by the Pro-only failure recipes. They abort by name rather than
  degrading into a demonstration of something else: a recipe that quietly
  showed you a simulated refund would be worse than no recipe.
  """
  @spec require!(String.t()) :: :ok
  def require!(what) do
    if @available do
      :ok
    else
      raise """
      #{what} needs the Pro profile, and this build does not have Aurora Meter Pro in it.

      The Pro profile is opt in:

          mix hex.organization auth phxtemplates --key "$AURORA_HEX_READ_KEY"
          export AURORA_SAMPLE_PRO=1
          mix deps.get
          mix ecto.migrate

      See README.md, section "The Pro profile", and .env.example for the
      variables it needs. Nothing here is simulated when Pro is absent: this
      refusal is the whole of the fallback, on purpose.
      """
    end
  end
end
