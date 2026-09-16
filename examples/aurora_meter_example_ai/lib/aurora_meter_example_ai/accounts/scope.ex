defmodule AuroraMeterExampleAi.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `AuroraMeterExampleAi.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias AuroraMeterExampleAi.Accounts.User
  alias AuroraMeterExampleAi.Orgs

  @typedoc """
  The caller. `org` is the Aurora Meter tenant for every call this caller
  makes, and it is set here, from the session, exactly once.
  """
  @type t :: %__MODULE__{user: User.t() | nil, org: Orgs.Org.t() | nil}

  defstruct user: nil, org: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.

  The organisation is attached here because this is the one place the session
  becomes a caller. Nothing downstream ever has to decide which organisation a
  request is for, so nothing downstream ever has the chance to decide wrongly.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user, org: Orgs.org_for_user(user)}
  end

  def for_user(nil), do: nil
end
