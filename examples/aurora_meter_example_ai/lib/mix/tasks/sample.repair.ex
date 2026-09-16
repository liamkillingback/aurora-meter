defmodule Mix.Tasks.Sample.Repair do
  @shortdoc "Rebuilds local rows for durable events this application never recorded"

  @moduledoc """
  Reconciles the orphan: a durable event that committed while this application
  was writing its own row, and died before it finished.

      mix sample.repair          # report only
      mix sample.repair --apply  # write the missing rows

  ## Why an orphan is possible at all

  `AuroraMeter.record/4` writes the event, its projection and its export intent
  in one transaction. This application writes its own `generations` row in a
  **second** statement afterwards, on purpose, because that is the simpler of
  the two shapes and it is the one most hosts start with. A process that dies
  between the two leaves the money right and the local history short a row.

  The alternative shape is to wrap both in one `Repo.transaction/2`: the event
  comes back with `durability: :conditional`, nothing is published until
  `AuroraMeter.Events.after_commit/1` runs, and a rollback removes the event,
  its total and its intent together. It costs a little more care, and the README
  shows it.

  ## What can and cannot be rebuilt

  The event carries the quantity, the model and the kind. It does **not** carry
  the prompt, and the export intent this application staged does not either,
  because a prompt is customer content and customer content does not belong in
  the thing that talks to a billing provider.

  So the rebuilt row has the right cost, the right token count and the right
  identity, and its prompt says it was not recovered. That is the honest answer
  and it is worth reading twice: **what you did not record durably, you cannot
  get back.**
  """
  use Mix.Task

  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Ops
  alias AuroraMeterExampleAi.Orgs
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.Tokens

  @unrecoverable "(not recovered: the prompt was never recorded durably)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    apply? = "--apply" in args

    Enum.each(Orgs.list_orgs(), fn org ->
      scope = %Scope{user: Orgs.owner(org), org: org}
      orphans = Ops.orphans(scope)

      Mix.shell().info("#{org.slug}: #{length(orphans)} orphan(s)")

      Enum.each(orphans, fn item ->
        Mix.shell().info("  #{item.event_id}  #{item.feature} #{item.quantity}")
        if apply?, do: rebuild(scope, item)
      end)
    end)

    unless apply?, do: Mix.shell().info("\nNothing was written. Pass --apply to rebuild.")
  end

  defp rebuild(%Scope{user: nil}, _item) do
    Mix.shell().error("  skipped: the organisation has no owner to attribute the row to")
  end

  defp rebuild(%Scope{} = scope, item) do
    total = item.quantity
    model = Map.get(item.payload, "dimensions", %{}) |> Map.get("model", "nimbus-1-mini")
    kind = Map.get(item.payload, "dimensions", %{}) |> Map.get("kind", "text")
    prompt_tokens = Tokens.prompt_tokens(@unrecoverable)
    completion = max(total - prompt_tokens, 0)

    attrs = %{
      id: id_from(item.event_id),
      org_id: scope.org.id,
      user_id: scope.user.id,
      kind: kind,
      prompt: @unrecoverable,
      model: model,
      status: "settled",
      prompt_tokens: prompt_tokens,
      completion_tokens: completion,
      cost_micros: Tokens.cost_micros(prompt_tokens, completion),
      event_id: item.event_id,
      hold_reference: item.event_id,
      inserted_at: item.inserted_at,
      settled_at: item.inserted_at
    }

    case %Generation{} |> Generation.changeset(attrs) |> Repo.insert() do
      {:ok, _generation} -> Mix.shell().info("    rebuilt")
      {:error, changeset} -> Mix.shell().error("    refused: #{inspect(changeset.errors)}")
    end
  end

  # The event id is `"gen:<uuid>"` and the row's primary key is the uuid. The
  # two are one identity written two ways, which is what lets this task line
  # them up at all.
  defp id_from("gen:" <> uuid), do: uuid
  defp id_from(other), do: other
end
