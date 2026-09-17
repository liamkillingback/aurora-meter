defmodule AuroraMeterExampleAiWeb.SampleComponents do
  @moduledoc """
  The sample's own small components: the navigation, and a labelled figure.

  Aurora Meter's own components (`usage_meter`, `usage_summary`, `spend_chart`,
  `credit_summary`) are used as shipped and are not wrapped here. They declare
  no colour and carry BEM class names, so they inherit whatever the host's
  design system has already set.
  """
  use Phoenix.Component

  attr :current_scope, :map, required: true

  def sample_nav(assigns) do
    ~H"""
    <nav class="flex gap-4 text-sm border-b pb-2 mb-4" aria-label="Sample">
      <.link navigate="/generate" class="link">Generate</.link>
      <.link navigate="/history" class="link">History</.link>
      <.link :if={owner?(@current_scope)} navigate="/ops" class="link">Operations</.link>
      <.link :if={owner?(@current_scope)} navigate="/dev/tools" class="link">Developer tools</.link>
      <.billing_link current_scope={@current_scope} />
      <span class="ml-auto opacity-60">
        {@current_scope.user.email} &middot; {@current_scope.org.slug}
      </span>
    </nav>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil

  def figure(assigns) do
    ~H"""
    <div class="flex justify-between border-b py-1 text-sm">
      <span>
        {@label}
        <span :if={@hint} class="opacity-60 text-xs">({@hint})</span>
      </span>
      <span class="font-mono">{@value}</span>
    </div>
    """
  end

  @doc """
  Formats micro-dollars for this sample.

  `AuroraMeter.Credits.Money.format_compact/1` rather than `format/1`, because
  one generation here costs a few hundred micro-dollars and `format/1`'s two
  decimal places round every one of them to `$0.00`. `format_compact/1` keeps
  just enough precision to stay non-zero, which is the difference between a
  page that shows the settlement and a page that shows a row of zeroes.

  A real application usually wants `format/2` with its own `:precision`. The
  thing to take from this is that a money helper's default precision is a
  display decision, and whether it is right depends on the size of your unit.
  """
  @spec money(integer() | nil) :: String.t()
  def money(nil), do: "-"
  def money(micros) when is_integer(micros), do: AuroraMeter.Credits.Money.format_compact(micros)

  # ---------------------------------------------------------------------------
  # The two profile-dependent affordances
  # ---------------------------------------------------------------------------
  #
  # Both are written as a **compile-time** `if` around two whole definitions
  # rather than as a runtime `:if` inside one. Three reasons, and the third is
  # the one that decided it:
  #
  #   1. the core profile compiles an empty component, so there is no branch to
  #      take on every render;
  #   2. the absence is structural. A reader grepping this file for "billing"
  #      in a core-profile checkout finds the explanation and no markup;
  #   3. `AuroraMeterExampleAi.Pro.available?/0` is a compile-time constant, and
  #      Elixir's type checker correctly reports a runtime `:if` on a constant
  #      as a branch that can never succeed. Writing the guard where it belongs
  #      removes the warning instead of silencing it.
  #
  # In the core profile these render nothing at all. Not a disabled button, not
  # a greyed link, not a note about what you would get if you paid: a disabled
  # control labelled "Billing" is a payment surface that does not work, and
  # this sample does not ship one.

  attr :current_scope, :map, required: true

  if AuroraMeterExampleAi.Pro.available?() do
    def billing_link(assigns) do
      ~H"""
      <.link :if={owner?(@current_scope)} navigate="/billing" class="link">Billing</.link>
      """
    end
  else
    def billing_link(assigns) do
      ~H""
    end
  end

  @doc """
  The top-up affordance on `/generate`, or nothing at all.

  It says where the money goes and when the credit arrives, because both are
  true and a reader who does not know the second one will refresh the page
  waiting for a figure that moves on a webhook.
  """
  attr :rest, :global

  if AuroraMeterExampleAi.Pro.available?() do
    def top_up_affordance(assigns) do
      ~H"""
      <p id="top-up-affordance" class="mt-2 text-sm" {@rest}>
        <.link navigate="/billing" class="link">Top up at Stripe</.link>
        <span class="opacity-60">
          (test mode; credit appears when the webhook lands, not when you come back)
        </span>
      </p>
      """
    end
  else
    def top_up_affordance(assigns) do
      ~H""
    end
  end

  defp owner?(%{user: %{role: "owner"}}), do: true
  defp owner?(_scope), do: false
end
