defmodule ReplicantServerWeb.Router do
  use ReplicantServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReplicantServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check for load balancers/Kamal
  scope "/health" do
    get "/", ReplicantServerWeb.HealthController, :index
  end

  scope "/api", ReplicantServerWeb do
    pipe_through :api
  end

  # Public routes (no auth)
  scope "/", ReplicantServerWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
    get "/", SessionController, :new
  end

  # Authenticated LiveView routes
  live_session :authenticated,
    on_mount: [{ReplicantServerWeb.LiveAuth, :default}],
    layout: {ReplicantServerWeb.Layouts, :app} do
    scope "/", ReplicantServerWeb do
      pipe_through :browser

      live "/documents", DocumentLive.Index, :index
      live "/documents/new", DocumentLive.Edit, :new
      live "/documents/:id", DocumentLive.Show, :show
      live "/documents/:id/edit", DocumentLive.Edit, :edit

      live "/public", DocumentLive.Public, :index
      live "/public/new", DocumentLive.Edit, :new_public
      live "/public/:id", DocumentLive.Show, :show_public
      live "/public/:id/edit", DocumentLive.Edit, :edit_public
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:replicant_server, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ReplicantServerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
