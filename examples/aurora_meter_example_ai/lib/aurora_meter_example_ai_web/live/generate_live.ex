defmodule AuroraMeterExampleAiWeb.GenerateLive do
  @moduledoc """
  The page the whole sample is arranged around: a prompt, a live usage meter, a
  live balance and a live spend chart, all of them updating without a reload and
  without a poll.

  ## Where the live figures come from

  Nothing on this page polls. `AuroraMeter.LiveView`'s hook subscribed this
  socket to this organisation's usage and credit topics at mount, and the two
  `handle_info/2` clauses below fold what arrives into assigns. A generation run
  in another browser tab, or by the API, or by a background job, moves this
  page's numbers within one broadcast interval.

  The helpers also drop a message belonging to another tenant, which matters
  the moment an application lets a user switch organisation: `unsubscribe`
  stops routing but does not empty a mailbox, so a broadcast already in flight
  arrives after the switch. That is why the payload carries `tenant_key`.

  ## The request id

  It is generated once, put in the form, and replaced **only after a success**.
  A double-clicked button therefore submits the same identity twice, which is
  refused at the credit hold before any work runs. Regenerating it on every
  render would turn the second click into a second charge, and that is the
  defect this arrangement exists to prevent.
  """
  use AuroraMeterExampleAiWeb, :live_view

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Generations
  alias AuroraMeterExampleAi.Tokens

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Generate")
     |> assign(:request_id, Ecto.UUID.generate())
     |> assign(:form, to_form(default_params()))
     |> assign(:result, nil)
     |> assign(:notice, nil)
     |> assign(:running, false)
     |> load_figures()}
  end

  @impl Phoenix.LiveView
  def handle_event("generate", %{"generation" => params}, socket) do
    request_id = params["request_id"] || socket.assigns.request_id

    case Generations.create(socket.assigns.current_scope, params, request_id) do
      {:ok, generation, outcome} ->
        {:noreply,
         socket
         # A fresh identity only now, after a success.
         |> assign(:request_id, Ecto.UUID.generate())
         |> assign(:result, generation)
         |> assign(:notice, notice_for(outcome))
         |> assign(:form, to_form(Map.put(params, "request_id", Ecto.UUID.generate())))
         |> load_figures()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:notice, {:error, describe(reason, socket)})
         |> load_figures()}
    end
  end

  # Usage. One message per feature whose counter moved, carrying the absolute
  # value for the current period rather than a delta.
  #
  # **The helpers take the message first and the socket second**, which is the
  # opposite way round from every other socket function in Phoenix, so the
  # natural `socket |> handle_usage(message)` is wrong. It does not raise: it
  # falls through to the helpers' catch-all clause, which returns its second
  # argument, so the pipe silently yields the message instead of the socket and
  # the failure surfaces somewhere else entirely. Written the way round below,
  # it reads oddly and works.
  @impl Phoenix.LiveView
  def handle_info({:aurora_meter, :usage, _payload} = message, socket) do
    {:noreply, message |> AuroraMeter.LiveView.handle_usage(socket) |> refresh_quotas()}
  end

  # Credits, and the low-balance flag that rides with them.
  def handle_info({:aurora_meter, tag, _payload} = message, socket)
      when tag in [:credits, :low_balance] do
    {:noreply, message |> AuroraMeter.LiveView.handle_credits(socket) |> refresh_credits()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  ## Rendering

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.sample_nav current_scope={@current_scope} />

      <h1 class="text-2xl font-semibold">Generate</h1>
      <p class="text-sm opacity-70">
        Organisation <strong>{@current_scope.org.name}</strong>
        on the <strong>{@plan_id}</strong>
        plan. Nothing on this page takes a payment.
      </p>

      <div :if={@low_balance} id="low-balance-banner" class="alert alert-warning" role="status">
        Low balance: {money(@summary.available)} left, which is under the {money(
          @low_balance_threshold
        )} threshold.
      </div>

      <div :if={@summary.debt > 0} id="debt-banner" class="alert alert-error" role="status">
        This wallet owes {money(@summary.debt)}. While it does, every hold and every
        debit is refused and both spendable figures read zero, whatever the balance
        says. A grant of any category clears it.
      </div>

      <.form for={@form} id="generate-form" phx-submit="generate">
        <input type="hidden" name="generation[request_id]" value={@request_id} />

        <label class="block text-sm font-medium" for="generation_prompt">Prompt</label>
        <textarea
          id="generation_prompt"
          name="generation[prompt]"
          rows="3"
          class="textarea textarea-bordered w-full"
        >{@form.params["prompt"]}</textarea>

        <div class="flex gap-4 mt-2">
          <label class="text-sm">
            Kind
            <select id="generation_kind" name="generation[kind]" class="select select-bordered">
              <option value="text" selected={@form.params["kind"] == "text"}>text</option>
              <option value="image" selected={@form.params["kind"] == "image"}>image</option>
            </select>
          </label>

          <label class="text-sm">
            Model
            <select id="generation_model" name="generation[model]" class="select select-bordered">
              <option
                :for={model <- Tokens.models()}
                value={model}
                selected={@form.params["model"] == model}
              >
                {model}
              </option>
            </select>
          </label>

          <button type="submit" phx-disable-with="Generating..." class="btn btn-primary">
            Generate
          </button>
        </div>
      </.form>

      <p class="text-xs opacity-60">
        A prompt beginning <code>fail:</code>
        makes the simulated workload raise, so you can watch the reservation and the
        hold both come back.
      </p>

      <div :if={@notice} id="notice" class="alert" role="status">{notice_text(@notice)}</div>

      <div :if={@result} id="result" class="card bg-base-200 p-4">
        <h2 class="font-semibold">Result</h2>
        <p class="text-xs opacity-70">
          id {@result.id} &middot; event {@result.event_id || "none"} &middot; status {@result.status}
        </p>
        <p :if={@result.cost_micros} class="text-sm">
          Estimated {money(@result.estimate_micros)}, settled {money(@result.cost_micros)} for {@result.prompt_tokens} prompt and {@result.completion_tokens} completion tokens.
        </p>
        <pre :if={@result.output} class="text-xs whitespace-pre-wrap">{@result.output}</pre>
      </div>

      <h2 class="text-lg font-semibold mt-6">This period</h2>
      <!--
        `data-usage={@usage_version}` is not decoration and it is not optional.

        `AuroraMeter.Components.usage_meter/1` calls `AuroraMeter.quota/2`
        inside itself, from the tenant it was given. Its output therefore
        depends on data that is not in its assigns, and LiveView's change
        tracking does not re-render a function component whose assigns did not
        change. A socket that is correctly subscribed, receiving the usage
        broadcast, and calling `AuroraMeter.LiveView.handle_usage/2` will still
        show a stale meter unless something in the invocation moves.

        `usage_version` is bumped on every usage message. It is carried into
        the component's `:rest` global attribute, so the invocation changes,
        so the component is re-rendered, so the figure is current. Without it
        this page is silently wrong, and the test
        "a generation in one session moves the meter ... in a second session"
        is what says so.
      -->
      <AuroraMeter.Components.usage_meter
        tenant={@current_scope.org}
        feature={:images}
        label="images"
        data-usage={@usage_version}
      />
      <AuroraMeter.Components.usage_meter
        tenant={@current_scope.org}
        feature={:tokens}
        label="tokens"
        data-usage={@usage_version}
      />

      <div id="balance" class="mt-4">
        <AuroraMeter.Components.credit_summary summary={@summary} />
      </div>

      <%!-- Absent in the core profile, and absent rather than disabled.

            The component has two definitions behind a COMPILE-TIME `if`, so
            without Aurora Meter Pro there is no markup here at all and nothing
            for a reader to click that would do nothing. A disabled button
            labelled "Top up" is a payment surface that does not work, which is
            the one thing a billing sample must never ship.

            `test/pro_absent_test.exs` asserts the absence and the presence, in
            both profiles, so neither half is taken on trust. --%>
      <.top_up_affordance />

      <div id="spend-chart" class="mt-4">
        <AuroraMeter.Components.spend_chart points={@spend_points} label="Spend per day" />
      </div>

      <p class="text-xs opacity-60 mt-2">
        Buffered counters are strict on one node and converge across nodes. This
        sample runs on one node, so what you see here is exact.
      </p>
    </Layouts.app>
    """
  end

  ## Assign plumbing

  defp load_figures(socket), do: socket |> refresh_credits() |> refresh_quotas() |> assign_plan()

  defp refresh_credits(socket) do
    org = socket.assigns.current_scope.org
    summary = Credits.summary(org)

    socket
    |> assign(:summary, summary)
    |> assign(:spend_points, Credits.spend_history(org, days: 14))
    |> assign(:low_balance_threshold, low_balance_threshold())
    |> assign(:low_balance, low_balance?(summary))
  end

  defp refresh_quotas(socket) do
    # The meters read `AuroraMeter.quota/2` themselves when they render, so
    # there is nothing to assign; touching an assign is what tells LiveView the
    # component's output may have changed.
    assign(socket, :usage_version, System.unique_integer([:monotonic]))
  end

  defp assign_plan(socket) do
    plan = AuroraMeter.plan(socket.assigns.current_scope.org)
    assign(socket, :plan_id, (plan && plan.id) || "none")
  end

  defp low_balance_threshold, do: AuroraMeter.Config.credits_low_balance_threshold() || 0

  defp low_balance?(summary) do
    threshold = low_balance_threshold()
    threshold > 0 and summary.available < threshold
  end

  defp default_params do
    %{"prompt" => "a short poem about a ledger", "kind" => "text", "model" => "nimbus-1-mini"}
  end

  defp notice_for(:created), do: {:info, "Generated."}

  defp notice_for(:duplicate),
    do: {:info, "That request had already been run. Nothing was charged twice."}

  defp notice_for(:recovered),
    do:
      {:info,
       "The usage had been recorded but the local record was missing. It has been rebuilt."}

  defp notice_text({_kind, text}), do: text

  defp describe(:insufficient_credits, socket),
    do: "Not enough credit. The balance is #{money(socket.assigns.summary.available)}."

  defp describe(:debt_outstanding, _socket),
    do: "This wallet owes money, so nothing can be spent until a grant clears the debt."

  defp describe(:limit_exceeded, socket) do
    quota = AuroraMeter.quota(socket.assigns.current_scope.org, :images)

    "The #{socket.assigns.plan_id} plan allows #{quota.limit} images this period and " <>
      "#{quota.used} have been used. The period ends #{quota.period.end}."
  end

  defp describe(:not_entitled, _socket), do: "This plan does not include that feature."

  defp describe(:already_failed, _socket),
    do: "That request has already been used. Start a new one."

  defp describe({:provider_failed, message}, _socket),
    do: "The work failed: #{message}. Nothing was charged and the quota was given back."

  defp describe({:conflict, existing}, _socket),
    do:
      "This request was already recorded with different content " <>
        "(event #{existing.event_id}, quantity #{existing.quantity}). Start a new request."

  defp describe({:invalid, errors}, _socket),
    do: "That request is not valid: #{inspect(errors)}."

  defp describe({:unavailable, _reason}, _socket),
    do: "The usage could not be recorded, so nothing was charged. Try the same request again."

  defp describe(other, _socket), do: "Refused: #{inspect(other)}."
end
