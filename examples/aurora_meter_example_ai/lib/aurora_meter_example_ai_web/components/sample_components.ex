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

  defp owner?(%{user: %{role: "owner"}}), do: true
  defp owner?(_scope), do: false
end
