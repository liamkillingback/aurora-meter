defmodule AuroraMeterExampleAiWeb.Router do
  use AuroraMeterExampleAiWeb, :router

  import AuroraMeterExampleAiWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AuroraMeterExampleAiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The metered API pipeline. Two things happen here and they are different
  # things:
  #
  #   * `ApiAuth.authenticate/2` says **who** this request is for. That is
  #     authentication and it is entirely the host's.
  #   * `AuroraMeter.Plug.EnsureEntitled` says whether that tenant's plan allows
  #     the feature at all. That is entitlement, and it is **advisory**: it
  #     holds nothing, so between its decision and the controller's work
  #     another request on this node can take the last unit. The controller
  #     still calls `with_quota/4`, which is where the money is.
  #
  # An application that checked only here would over-serve by roughly the number
  # of requests it had in flight when the cap was reached.
  pipeline :metered_api do
    plug :accepts, ["json"]
    plug AuroraMeterExampleAiWeb.ApiAuth, :authenticate

    plug AuroraMeter.Plug.EnsureEntitled,
      feature: :images,
      tenant: {AuroraMeterExampleAiWeb.ApiAuth, :org},
      on_denied: {AuroraMeterExampleAiWeb.ApiErrors, :denied},
      on_missing_tenant: {AuroraMeterExampleAiWeb.ApiErrors, :denied}
  end

  scope "/", AuroraMeterExampleAiWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", AuroraMeterExampleAiWeb do
    pipe_through :metered_api

    post "/generate", Api.GenerationController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:aurora_meter_example_ai, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AuroraMeterExampleAiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## The metered pages

  # The hook order is the load-bearing part and it reads top to bottom:
  #
  #   1. the host authenticates the user;
  #   2. the host decides which organisation that user acts for, from the
  #      session, and assigns it;
  #   3. Aurora Meter subscribes the socket to **that** organisation's usage and
  #      credit topics.
  #
  # Step 3 never does step 1 or step 2. `AuroraMeter.LiveView` reads the assign
  # in front of it and subscribes; it has no opinion about who may see what, and
  # it will not grow one.
  scope "/", AuroraMeterExampleAiWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :metered,
      on_mount: [
        {AuroraMeterExampleAiWeb.UserAuth, :require_authenticated},
        {AuroraMeterExampleAiWeb.OrgHook, :assign_org},
        {AuroraMeter.LiveView, {:subscribe, assign: :current_org, topics: [:usage, :credits]}}
      ] do
      live "/generate", GenerateLive, :new
      live "/history", HistoryLive, :index
      live "/history/:id", HistoryLive, :show
    end

    # Operational pages. Same three hooks, plus the host's own owner check in
    # front of them: one organisation's internals are for that organisation's
    # owner, and that is the host's decision to take.
    live_session :operations,
      on_mount: [
        {AuroraMeterExampleAiWeb.UserAuth, :require_owner},
        {AuroraMeterExampleAiWeb.OrgHook, :assign_org},
        {AuroraMeter.LiveView, {:subscribe, assign: :current_org, topics: [:usage, :credits]}}
      ] do
      live "/ops", OpsLive, :index
      live "/dev/tools", DevToolsLive, :index
    end
  end

  ## Authentication routes

  scope "/", AuroraMeterExampleAiWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{AuroraMeterExampleAiWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", AuroraMeterExampleAiWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{AuroraMeterExampleAiWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
