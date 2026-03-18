defmodule LibrarianWeb.Router do
  use LibrarianWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LibrarianWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LibrarianWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/reader", ReaderLive, :index
    live "/reader/feed/:feed_id", ReaderLive, :feed
    live "/reader/category/:category", ReaderLive, :category

    live "/vault", VaultLive, :index
    live "/vault/notebook/:notebook_id", VaultLive, :notebook

    live "/search", SearchLive, :index

    live "/settings", SettingsLive, :index

    get "/vault/files/*key", VaultFilesController, :show
  end

  scope "/api", LibrarianWeb do
    pipe_through :api

    post "/clips", ClipController, :create
    get "/notebooks", NotebookApiController, :index
  end

  if Application.compile_env(:librarian, :dev_routes) do
    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
