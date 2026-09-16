defmodule AuroraMeter.LiveDashboard.Auth do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch. A host mounts
  `AuroraMeter.LiveDashboard.Page`; this is what that page is built from.

  The authorization contract both LiveDashboard pages are registered with.

  A library page mounted inside `Phoenix.LiveDashboard` cannot inspect the
  host's router pipelines, cannot know who is signed in, and must not invent an
  authorization rule. The two things it can do are done here: **refuse to exist
  until the host makes an explicit statement**, and **evaluate a host-supplied
  check on every mount and every refresh**.

  There is no default and no implicit "allow". `validate!/2` accepts three
  forms and nothing else:

  | Value | Meaning | Allowed on |
  |---|---|---|
  | `{module, function, args}` | called as `module.function(socket, args)`, must return exactly `true` | core page, Pro page |
  | `{:assign, key}` | requires `socket.assigns[key] == true` | core page, Pro page |
  | `:host_route` | an explicit statement that the route itself is authenticated and that node-local aggregates may be shown | **core page only** |

  `:host_route` is refused by the Pro page with its own message, because the Pro
  page renders tenant keys, provider references and payment state, and an
  operator marker is not an acceptable basis for showing another customer's
  payment state. The core page may accept it because it renders **no
  tenant-identifying value at all**: every core section is a node-local
  aggregate, a checkpoint position or a configuration value. That asymmetry is
  the substantive control; the marker is the procedural one.

  The host wiring both moduledocs show:

      # router.ex, inside an already-authenticated scope
      live_dashboard "/dashboard",
        metrics: MyApp.Telemetry,
        on_mount: [{MyAppWeb.Admin, :ensure_operator}],
        additional_pages: [
          aurora_meter: {AuroraMeter.LiveDashboard.Page, authorized_by: {:assign, :operator?}}
        ]

  ## What this does not promise

  `architecture-map.md` section 9 says both pages "require the host to mount
  them inside an authenticated dashboard route". That is a statement about the
  host, and a library cannot enforce it. What is enforced here is that the host
  wrote a decision down, and that the decision is re-read on every refresh so a
  session that loses its marker stops seeing data without waiting for a
  remount. The residual risk is the host's `on_mount` hook, and the mitigation
  that does not depend on the host is that the core page renders no tenant data
  at all.
  """

  require Logger

  @typedoc "The three accepted forms of the `:authorized_by` option."
  @type check :: {module(), atom(), term()} | {:assign, atom()} | :host_route

  @forms """
  Accepted forms:

    * {Module, :function, args}  - called as Module.function(socket, args) and
      must return exactly true
    * {:assign, :key}            - requires socket.assigns[:key] == true, set by
      an on_mount hook on the live_dashboard route
    * :host_route                - core page only: an explicit statement that
      the route itself is authenticated
  """

  @doc """
  Returns the `:authorized_by` value from `opts`, or raises `ArgumentError`.

  `page` is `:core` or `:pro`; the Pro page refuses `:host_route`.

  ## Examples

      iex> AuroraMeter.LiveDashboard.Auth.validate!([authorized_by: :host_route], :core)
      :host_route

      iex> AuroraMeter.LiveDashboard.Auth.validate!([authorized_by: {:assign, :op?}], :pro)
      {:assign, :op?}

  """
  @spec validate!(keyword(), :core | :pro) :: check()
  def validate!(opts, page) when is_list(opts) and page in [:core, :pro] do
    case Keyword.fetch(opts, :authorized_by) do
      :error -> raise ArgumentError, missing_message(page)
      {:ok, value} -> validate_value!(value, page)
    end
  end

  def validate!(other, page) when page in [:core, :pro] do
    raise ArgumentError,
          "the Aurora Meter dashboard page takes a keyword list of options, got: " <>
            inspect(other) <> "\n\n" <> @forms
  end

  @doc """
  Whether `check` allows `socket` to see data.

  Exactly `true` allows it. Anything else, including a truthy value that is not
  `true`, refuses. A check that **raises** is treated as a refusal and logged at
  `:warning`: a page must not open because somebody's authorization function has
  a bug in it.

  ## Examples

      iex> AuroraMeter.LiveDashboard.Auth.allowed?({:assign, :op?}, %{assigns: %{op?: true}})
      true

      iex> AuroraMeter.LiveDashboard.Auth.allowed?({:assign, :op?}, %{assigns: %{op?: "yes"}})
      false

      iex> AuroraMeter.LiveDashboard.Auth.allowed?(:host_route, %{assigns: %{}})
      true

  """
  @spec allowed?(check(), map()) :: boolean()
  def allowed?(:host_route, _socket), do: true

  def allowed?({:assign, key}, socket) when is_atom(key) do
    socket |> assigns() |> Map.get(key) == true
  end

  def allowed?({module, function, args}, socket)
      when is_atom(module) and is_atom(function) do
    apply(module, function, [socket, args]) == true
  rescue
    error ->
      Logger.warning(
        "Aurora Meter dashboard authorization check " <>
          "#{inspect(module)}.#{function}/2 raised, so the page is refused: " <>
          Exception.message(error)
      )

      false
  catch
    kind, reason ->
      Logger.warning(
        "Aurora Meter dashboard authorization check " <>
          "#{inspect(module)}.#{function}/2 exited (#{kind}), so the page is refused: " <>
          inspect(reason)
      )

      false
  end

  @doc """
  A short description of `check` for the refusal panel.

  It names the configured check so an operator seeing the refusal can find the
  hook that should have set it. It never renders a value the check read.

  ## Examples

      iex> AuroraMeter.LiveDashboard.Auth.describe({:assign, :operator?})
      "the assign :operator? is not exactly true"

  """
  @spec describe(check()) :: String.t()
  def describe({:assign, key}), do: "the assign #{inspect(key)} is not exactly true"

  def describe({module, function, _args}),
    do: "#{inspect(module)}.#{function}/2 did not return true"

  def describe(:host_route), do: "the host route did not authorize this session"

  # -- validation ------------------------------------------------------------

  defp validate_value!(:host_route, :core), do: :host_route

  defp validate_value!(:host_route, :pro) do
    raise ArgumentError, """
    AuroraMeter.Pro.LiveDashboard.Page refuses authorized_by: :host_route.

    The Pro page renders tenant keys, provider references and payment state.
    ":host_route" says only that the route is authenticated, which is not a
    basis for showing one customer's payment state to whoever reached the
    dashboard. Give it a real check instead:

      {:assign, :operator?}        with an on_mount hook that sets it, or
      {MyApp.Admin, :operator?, []}

    The core page (AuroraMeter.LiveDashboard.Page) does accept :host_route,
    because it renders no tenant-identifying value at all.
    """
  end

  defp validate_value!({:assign, key} = value, _page) when is_atom(key), do: value

  defp validate_value!({module, function, _args} = value, _page)
       when is_atom(module) and is_atom(function),
       do: value

  defp validate_value!(other, page) do
    raise ArgumentError,
          "#{page_module(page)} was given authorized_by: #{inspect(other)}, which is not " <>
            "one of the accepted forms.\n\n" <> @forms
  end

  defp missing_message(page) do
    """
    #{page_module(page)} requires the :authorized_by option and there is no default.

    A library page cannot know who is signed in, so it will not guess. Say what
    authorizes it:

        additional_pages: [
          aurora_meter: {#{page_module(page)}, authorized_by: {:assign, :operator?}}
        ]

    #{@forms}
    """
  end

  defp page_module(:core), do: "AuroraMeter.LiveDashboard.Page"
  defp page_module(:pro), do: "AuroraMeter.Pro.LiveDashboard.Page"

  defp assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp assigns(_socket), do: %{}
end
