defmodule AuroraMeterExampleAi.Generations do
  @moduledoc """
  The one function this whole sample exists to show: `create/3`.

  Read it top to bottom. In order it does a quota check that reserves, a credit
  hold for an estimate, the work, a durable record of what the work actually
  used, a settlement for the real cost, and only then this application's own
  row. Every one of those steps can fail, and what each failure leaves behind is
  the interesting part.

  ## The two gating styles, in one application

  An **image** request is gated twice: `AuroraMeter.with_quota/4` takes one of
  the plan's image slots, and the credit ledger pays for the tokens inside it.
  A **text** request is gated only by credit. That is not indecision: a hard
  quota and a prepaid balance answer different questions ("is this plan allowed
  to do this at all" and "can this customer afford it"), and an application
  usually has both.

  ## Why a refusal inside `with_quota/4` has to be raised

  `AuroraMeter.with_quota/4` commits its reservation on **any** normal return,
  including `{:error, :insufficient_credits}` from the code inside it. It
  catches raises, throws and exits, releases the reservation and re-raises, and
  that is the only channel it has for "the work did not happen". So a business
  refusal that happens inside the callback has to leave as an exception and be
  turned back into a tuple outside, which is what `Refused` below is for.

  This is the sharpest edge in the whole integration and it is worth saying out
  loud: **if you return an error tuple from inside `with_quota/4`, you have
  billed a quota unit for work you did not do**, and nothing will tell you.

  ## Identity: one string, three systems

  `request_id` is a UUID the browser puts in the form and only replaces after a
  success. It becomes:

    * the `generations` row's primary key, so a double insert is a constraint
      violation;
    * the credit hold reference `"gen:<id>"`, so a double submit is
      `{:error, :duplicate_reference}` before any work runs;
    * the Aurora Meter event id `"gen:<id>"`, so a repeated `record/4` is
      reported as a duplicate rather than persisted twice.

  A double-clicked button is therefore refused three times over, and the first
  refusal happens before a single token is generated.

  ## The orphan, and why `record/4`'s conflict answer is load bearing

  The durable event and this application's row are written in **separate**
  transactions, deliberately (the simpler of the two teaching options; the
  other is in the README). So a process that dies between them leaves an event
  with no local row. A retry of that request id is then refused at the hold,
  finds no row to show, and has to ask Aurora Meter what it already recorded.
  That is where `{:ok, event, :duplicate}` and `{:error, {:conflict, existing}}`
  earn their place: the first rebuilds the row, the second says the caller has
  reused one identity for two different requests. `mix sample.repair` does the
  same thing in bulk.
  """

  import Ecto.Query, warn: false

  alias AuroraMeter.Credits
  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Orgs
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleOutbox.Item
  alias AuroraMeterExampleAi.Tenancy
  alias AuroraMeterExampleAi.Tokens

  defmodule Refused do
    @moduledoc """
    Carries a business refusal out of a `with_quota/4` callback.

    It exists only because returning the refusal would commit the reservation.
    See the module documentation of `AuroraMeterExampleAi.Generations`.
    """
    defexception [:reason]

    @impl Exception
    def message(%__MODULE__{reason: reason}),
      do: "refused before any work ran: #{inspect(reason)}"
  end

  @type outcome ::
          {:ok, Generation.t(), :created | :duplicate | :recovered}
          | {:error,
             :limit_exceeded
             | :not_entitled
             | :insufficient_credits
             | :debt_outstanding
             | :already_failed
             | {:conflict, map()}
             | {:invalid, [{atom(), term()}]}
             | {:unavailable, term()}}

  @doc """
  Runs one generation for this caller's organisation.

  `attrs` needs `"kind"` (`"text"` or `"image"`), `"prompt"` and `"model"`.
  `request_id` is the caller's identity for this request and must be stable
  across a retry of the same request.

  Returns `{:ok, generation, :created}` for work that ran,
  `{:ok, generation, :duplicate}` when this request id had already completed,
  `{:ok, generation, :recovered}` when the durable event existed but this
  application's row did not, and `{:error, reason}` otherwise.
  """
  @spec create(Scope.t(), map(), String.t()) :: outcome()
  def create(%Scope{} = scope, attrs, request_id) when is_binary(request_id) do
    org = Tenancy.org!(scope)

    with {:ok, params} <- validate(attrs, request_id) do
      reference = reference(request_id)

      try do
        case gated(org, params, reference) do
          {:ok, done} ->
            persist(scope, params, request_id, reference, done)

          # Every path that has already used this request id lands here: a
          # second click, a retry after a failure, and a retry of a request
          # whose event committed but whose row did not.
          {:error, :duplicate_reference} ->
            replay(scope, params, request_id, reference)

          # The work succeeded and could not be recorded. The hold was
          # released, so nothing was charged, and the row says `released` so
          # the customer can see the attempt.
          {:error, {:unavailable, reason}} ->
            failed(scope, params, request_id, reference, "released")
            {:error, {:unavailable, reason}}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        error in Tokens.ProviderError ->
          # `with_credits/4` has released the hold and, for an image request,
          # `with_quota/4` has released the reservation, both on the way out.
          # Nothing at all has been billed. The row is written so the failure
          # is visible in the history rather than only in a flash message.
          failed(scope, params, request_id, reference, "rejected")
          {:error, {:provider_failed, Exception.message(error)}}
      end
    end
  end

  @doc "The credit hold reference and Aurora Meter event id for a request id."
  @spec reference(String.t()) :: String.t()
  def reference(request_id), do: "gen:" <> request_id

  ## The gated path

  @spec gated(Orgs.Org.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp gated(org, %{kind: "image"} = params, reference) do
    AuroraMeter.with_quota(org, :images, 1, fn ->
      case metered(org, params, reference) do
        {:ok, done} -> done
        {:error, reason} -> raise Refused, reason: reason
      end
    end)
  rescue
    # The reservation has already been released by `with_quota/4` on its way
    # out. All that is left is to turn the exception back into the tuple the
    # caller was always going to get.
    error in Refused -> {:error, error.reason}
  end

  defp gated(org, %{kind: "text"} = params, reference), do: metered(org, params, reference)

  @spec metered(Orgs.Org.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp metered(org, params, reference) do
    estimate = Tokens.estimate(params.prompt, params.model)

    Credits.with_credits(org, estimate, reference, fn ->
      {prompt_tokens, completion_tokens, output} = Tokens.run(params.prompt, params.model)
      total = prompt_tokens + completion_tokens
      actual = Tokens.cost_micros(prompt_tokens, completion_tokens)

      # Recorded inside the hold and outside any transaction of this
      # application's own. Because there is no surrounding transaction, the
      # event is durable the moment this returns and `AuroraMeter.Events`
      # needs no `after_commit/1` call. A host that wraps this and its own row
      # in one `Repo.transaction/2` gets `durability: :conditional` back and
      # must call `AuroraMeter.Events.after_commit/1` after its commit.
      case AuroraMeter.record(org, :tokens, total,
             id: reference,
             occurred_at: DateTime.utc_now(),
             dimensions: %{"model" => params.model, "kind" => params.kind},
             metadata: %{"generation_id" => strip(reference)}
           ) do
        {:ok, event, recorded} ->
          {:ok,
           %{
             status: "settled",
             prompt_tokens: prompt_tokens,
             completion_tokens: completion_tokens,
             output: output,
             cost_micros: actual,
             estimate_micros: estimate,
             event_id: event.event_id,
             recorded: recorded,
             settled_at: DateTime.utc_now()
           }, actual}

        {:error, reason} ->
          # Returning an error here releases the hold and gives the tuple back
          # unchanged. The work ran and cost this application real CPU, and the
          # customer is charged nothing, which is the right way round.
          {:error, record_error(reason)}
      end
    end)
  end

  @spec record_error(term()) :: term()
  defp record_error({:conflict, existing}), do: {:conflict, existing}
  defp record_error({:invalid, errors}), do: {:invalid, errors}
  defp record_error({:unavailable, reason}), do: {:unavailable, reason}
  defp record_error(other), do: other

  ## Persisting this application's own row

  @spec persist(Scope.t(), map(), String.t(), String.t(), map()) :: outcome()
  defp persist(scope, params, request_id, reference, done) do
    attrs =
      done
      |> Map.drop([:recorded])
      |> Map.merge(%{
        id: request_id,
        org_id: scope.org.id,
        user_id: scope.user.id,
        kind: params.kind,
        prompt: params.prompt,
        model: params.model,
        hold_reference: reference,
        inserted_at: DateTime.utc_now()
      })

    case %Generation{} |> Generation.changeset(attrs) |> Repo.insert() do
      {:ok, generation} ->
        {:ok, generation, :created}

      {:error, changeset} ->
        # Another caller holding the same request id got here first. Twelve
        # concurrent submits of one identity all reach this line; exactly one
        # of them inserted. The primary key IS the request id, which is what
        # makes the race a constraint violation rather than a second row.
        case get(scope, request_id) do
          %Generation{} = existing -> {:ok, existing, :duplicate}
          nil -> {:error, {:invalid, changeset_errors(changeset)}}
        end
    end
  end

  @spec failed(Scope.t(), map(), String.t(), String.t(), String.t()) :: :ok
  defp failed(scope, params, request_id, reference, status) do
    persist(scope, params, request_id, reference, %{
      status: status,
      estimate_micros: Tokens.estimate(params.prompt, params.model)
    })

    :ok
  end

  ## A request id that has been used before

  @spec replay(Scope.t(), map(), String.t(), String.t()) :: outcome()
  defp replay(scope, params, request_id, reference) do
    case get(scope, request_id) do
      %Generation{status: "settled"} = generation ->
        if same_request?(generation, params) do
          {:ok, generation, :duplicate}
        else
          # I07 at the application level, and this is where it has to live.
          # `AuroraMeter.record/4` refuses a changed payload under a used
          # identity, but the **prompt is not in the payload**: the event
          # carries a token count, a model and a kind, and nothing a customer
          # typed. So the library cannot see that this is a different request
          # and the application can. Deciding what "the same request" means is
          # the host's, every time.
          {:error, {:conflict, %{event_id: generation.event_id, prompt: generation.prompt}}}
        end

      %Generation{} ->
        # The first attempt failed and its row says so. A request id is spent
        # once, whatever the outcome, because the hold reference it produced is
        # unique for ever. Retrying needs a new one.
        {:error, :already_failed}

      nil ->
        recover(scope, params, request_id, reference)
    end
  end

  defp same_request?(%Generation{} = generation, params) do
    generation.prompt == params.prompt and generation.model == params.model and
      generation.kind == params.kind
  end

  # No local row, but the reference has been used: the event and its export
  # intent committed and this application died before writing its own row.
  #
  # **What is read back is this application's own outbox row, not the library's
  # tables.** `AuroraMeter.record/4` staged that row inside the transaction
  # that wrote the event, so it exists exactly when the event exists and it
  # carries the quantity that was recorded. A host that implements the outbox
  # seam gets a durable local record of everything it recorded, for free, and
  # never has to ask the library what it did.
  #
  # The alternative, asking `record/4` again with the same id, does not work
  # here and the reason is worth knowing: the payload identity includes
  # `occurred_at` to the microsecond, so a retry that stamps a fresh `now`
  # comes back as `{:error, {:conflict, _}}` rather than as
  # `{:ok, event, :duplicate}`. "Retry with the same id" means retry with the
  # same id **and the same payload**, and a caller that did not persist the
  # payload before the call cannot reproduce it after a crash.
  @spec recover(Scope.t(), map(), String.t(), String.t()) :: outcome()
  defp recover(scope, params, request_id, reference) do
    case Repo.get_by(Item, tenant_key: Tenancy.to_key(Tenancy.org!(scope)), event_id: reference) do
      %Item{state: state} = item when state != "skipped" ->
        rebuild(scope, params, request_id, reference, item)

      _ ->
        # The hold was taken and nothing was ever recorded under it. Nothing to
        # recover, and the identity is spent.
        {:error, :already_failed}
    end
  end

  @spec rebuild(Scope.t(), map(), String.t(), String.t(), Item.t()) :: outcome()
  defp rebuild(scope, params, request_id, reference, %Item{} = item) do
    prompt_tokens = Tokens.prompt_tokens(params.prompt)
    completion = max(item.quantity - prompt_tokens, 0)

    done = %{
      status: "settled",
      prompt_tokens: prompt_tokens,
      completion_tokens: completion,
      # The output was never durable. Nothing in the metering system carries
      # customer content, and that is a decision rather than an oversight.
      output: nil,
      cost_micros: Tokens.cost_micros(prompt_tokens, completion),
      estimate_micros: Tokens.estimate(params.prompt, params.model),
      event_id: item.event_id,
      settled_at: item.inserted_at
    }

    case persist(scope, params, request_id, reference, done) do
      {:ok, generation, :created} -> {:ok, generation, :recovered}
      {:ok, generation, :duplicate} -> {:ok, generation, :duplicate}
      other -> other
    end
  end

  ## Reading, always through the scope

  @doc """
  This organisation's generations, newest first.

  Note the shape: the scope is the first argument and there is no variant that
  takes an organisation id. That is the whole of the isolation story.
  """
  @spec list(Scope.t(), keyword()) :: [Generation.t()]
  def list(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Generation
    |> Orgs.scope_query(scope)
    |> order_by([g], desc: g.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "One generation belonging to this organisation, or `nil`."
  @spec get(Scope.t(), String.t()) :: Generation.t() | nil
  def get(%Scope{} = scope, id) when is_binary(id) do
    if valid_uuid?(id) do
      Generation |> Orgs.scope_query(scope) |> Repo.get(id)
    end
  end

  @doc """
  One generation belonging to this organisation, raising `Ecto.NoResultsError`
  otherwise.

  A generation belonging to another organisation raises exactly as one that
  does not exist does, because from this caller's side those are the same fact.
  """
  @spec get!(Scope.t(), String.t()) :: Generation.t()
  def get!(%Scope{} = scope, id) when is_binary(id) do
    case get(scope, id) do
      nil -> raise Ecto.NoResultsError, queryable: Generation
      generation -> generation
    end
  end

  @doc "How many generations this organisation has, by status."
  @spec counts(Scope.t()) :: %{String.t() => non_neg_integer()}
  def counts(%Scope{} = scope) do
    Generation
    |> Orgs.scope_query(scope)
    |> group_by([g], g.status)
    |> select([g], {g.status, count(g.id)})
    |> Repo.all()
    |> Map.new()
  end

  ## Validation

  @spec validate(map(), String.t()) :: {:ok, map()} | {:error, {:invalid, [{atom(), term()}]}}
  defp validate(attrs, request_id) do
    kind = to_string(attrs["kind"] || attrs[:kind] || "text")
    prompt = String.trim(to_string(attrs["prompt"] || attrs[:prompt] || ""))
    model = to_string(attrs["model"] || attrs[:model] || "")

    errors =
      []
      |> put_error(kind not in ~w(text image), {:kind, :must_be_text_or_image})
      |> put_error(prompt == "", {:prompt, :required})
      |> put_error(byte_size(prompt) > 2_000, {:prompt, :too_long})
      |> put_error(model not in Tokens.models(), {:model, :unknown})
      |> put_error(not valid_uuid?(request_id), {:request_id, :must_be_a_uuid})

    case errors do
      [] -> {:ok, %{kind: kind, prompt: prompt, model: model}}
      errors -> {:error, {:invalid, Enum.reverse(errors)}}
    end
  end

  defp put_error(errors, true, error), do: [error | errors]
  defp put_error(errors, false, _error), do: errors

  @spec valid_uuid?(term()) :: boolean()
  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp strip("gen:" <> rest), do: rest

  defp changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
  end
end
