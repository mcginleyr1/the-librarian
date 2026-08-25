defmodule LibrarianWeb.Router do
  use LibrarianWeb, :router

  import Oban.Web.Router
  import LibrarianWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LibrarianWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :require_api_token
  end

  # Stripe calls this; auth is the webhook signature, not a session.
  pipeline :webhooks do
    plug :accepts, ["json"]
  end

  scope "/", LibrarianWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/login", PageController, :login
  end

  scope "/", LibrarianWeb do
    pipe_through :browser

    # Landing page when billing is enabled; otherwise redirects (in → /reader,
    # out → /login).
    get "/", PageController, :home

    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :delete
  end

  # Signed in but not necessarily subscribed: the plan picker must stay
  # reachable, otherwise unsubscribed users could never pay.
  scope "/", LibrarianWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/subscribe", BillingController, :subscribe
    post "/subscribe/checkout", BillingController, :checkout
    post "/billing/portal", BillingController, :portal
  end

  scope "/", LibrarianWeb do
    pipe_through [:browser, :require_authenticated_user, :require_active_subscription]

    get "/vault/files/*key", VaultFilesController, :show

    live_session :require_authenticated_user,
      on_mount: [
        {LibrarianWeb.UserAuth, :ensure_authenticated},
        {LibrarianWeb.UserAuth, :ensure_subscribed}
      ] do
      live "/foryou", ForYouLive, :index
      live "/dashboard", DashboardLive, :index

      live "/reader", ReaderLive, :index
      live "/reader/feed/:feed_id", ReaderLive, :feed
      live "/reader/category/:category", ReaderLive, :category

      live "/vault", VaultLive, :index
      live "/vault/notebook/:notebook_id", VaultLive, :notebook
      live "/vault/note/:note_id", VaultLive, :note
      live "/vault/graph", GraphLive, :index

      live "/search", SearchLive, :index

      live "/settings", SettingsLive, :index
    end
  end

  scope "/" do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    oban_dashboard("/oban")
  end

  scope "/webhooks", LibrarianWeb do
    pipe_through :webhooks

    post "/stripe", StripeWebhookController, :create
  end

  scope "/api", LibrarianWeb do
    pipe_through :api

    post "/clips", ClipController, :create
    get "/notebooks", NotebookApiController, :index
  end
end
