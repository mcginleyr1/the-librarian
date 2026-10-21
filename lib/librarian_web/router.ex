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
    plug :put_content_security_policy
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :require_api_token
  end

  scope "/", LibrarianWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/login", PageController, :login
  end

  scope "/", LibrarianWeb do
    pipe_through :browser

    get "/", PageController, :home

    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :delete
  end

  scope "/", LibrarianWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/vault/files/*key", VaultFilesController, :show

    live_session :require_authenticated_user,
      on_mount: [{LibrarianWeb.UserAuth, :ensure_authenticated}] do
      live "/foryou", ForYouLive, :index
      live "/dashboard", DashboardLive, :index

      live "/reader", ReaderLive, :index
      live "/reader/feed/:feed_id", ReaderLive, :feed
      live "/reader/category/:category", ReaderLive, :category

      live "/vault", VaultLive, :index
      live "/vault/notebook/:notebook_id", VaultLive, :notebook
      live "/vault/note/:note_id", VaultLive, :note
      live "/vault/graph", GraphLive, :index

      live "/canvas", CanvasLive, :index
      live "/canvas/:id", CanvasLive, :show

      live "/search", SearchLive, :index

      live "/settings", SettingsLive, :index
    end
  end

  scope "/" do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    oban_dashboard("/oban", csp_nonce_assign_key: :csp_nonce)
  end

  scope "/api", LibrarianWeb do
    pipe_through :api

    post "/clips", ClipController, :create
    get "/notebooks", NotebookApiController, :index
    get "/notes", NoteApiController, :index
    get "/notes/:id", NoteApiController, :show
    put "/notes/external/:external_id", NoteApiController, :sync
  end

  # Feed articles and clips are third-party HTML rendered in this origin; the
  # policy is the backstop if sanitizing ever misses. Scripts load only from
  # this origin or carry the per-request nonce (root layout theme script,
  # Oban Web). Images, media and embeds may come from anywhere.
  defp put_content_security_policy(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    policy =
      Enum.join(
        [
          "default-src 'self'",
          "script-src 'self' 'nonce-#{nonce}'",
          "style-src 'self' 'unsafe-inline'",
          "img-src * data: blob:",
          "media-src * data: blob:",
          "font-src 'self' data:",
          "connect-src 'self' ws://#{conn.host}:* wss://#{conn.host}:*",
          "frame-src 'self' https:",
          "object-src 'none'",
          "base-uri 'self'",
          "form-action 'self'",
          "frame-ancestors 'self'"
        ],
        "; "
      )

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy)
  end
end
