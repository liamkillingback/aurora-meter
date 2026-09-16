defmodule AuroraMeterExampleAiWeb.OrgHook do
  @moduledoc """
  Puts this caller's organisation on the socket as `:current_org`, from the
  session scope and from nowhere else.

  It is the middle of a three-hook chain, and the order is the whole point:

      on_mount: [
        {AuroraMeterExampleAiWeb.UserAuth, :require_authenticated},
        AuroraMeterExampleAiWeb.OrgHook,
        {AuroraMeter.LiveView, {:subscribe, assign: :current_org}}
      ]

  The host authenticates, the host decides which organisation this caller acts
  for, and only then does Aurora Meter subscribe to that organisation's topics.
  `AuroraMeter.LiveView` never authorizes anything and never decides whose data
  you are looking at; it reads the assign the hook before it set. Putting the
  Aurora hook first, or leaving the host's hook out, would subscribe a socket to
  whatever it could resolve.
  """

  import Phoenix.Component, only: [assign: 3]

  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Orgs.Org

  @doc false
  def on_mount(:default, params, session, socket),
    do: on_mount(:assign_org, params, session, socket)

  def on_mount(:assign_org, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %Scope{org: %Org{} = org} ->
        {:cont, assign(socket, :current_org, org)}

      _other ->
        # A signed-in user with no organisation is a broken seed, not a caller
        # to guess for. Aurora Meter's hook would halt with `:missing_tenant`
        # anyway; halting here says which layer could not answer.
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Your account has no organisation.")
         |> Phoenix.LiveView.redirect(to: "/users/log-in")}
    end
  end
end
