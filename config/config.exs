# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :librarian,
  ecto_repos: [Librarian.Repo],
  generators: [timestamp_type: :utc_datetime],
  embedding_model: "sentence-transformers/all-MiniLM-L6-v2",
  start_embedding_serving: true

# Register the pgvector type so Postgrex can encode/decode vector columns
config :librarian, Librarian.Repo, types: Librarian.PostgrexTypes

# Operator allowlist (override with ALLOWED_EMAILS). With billing disabled
# only these emails may log in; with billing enabled they are the comped
# admin accounts and anyone else may sign up and subscribe.
config :librarian, :allowed_emails, ["owner@example.com"]

# Stripe billing. Unset secret key / price ids = self-hosted mode: no landing
# page, no payments, sign-in restricted to :allowed_emails. The *_usd values
# are display-only — keep them in sync with the Stripe prices.
config :librarian, :billing,
  stripe_secret_key: nil,
  stripe_webhook_secret: nil,
  monthly_price_id: nil,
  yearly_price_id: nil,
  monthly_price_usd: 12,
  yearly_price_usd: 96,
  trial_days: 14

# Platform Anthropic key: used for users who haven't set their own key in
# Settings, capped per user per month by :platform_llm_budget_cents so LLM
# spend can never outrun the subscription fee.
config :librarian, :platform_anthropic_api_key, nil
config :librarian, :platform_llm_budget_cents, 500

config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ]

# Run Nx/Bumblebee computations through EXLA (CPU)
config :nx, default_backend: EXLA.Backend

# Configure the endpoint
config :librarian, LibrarianWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LibrarianWeb.ErrorHTML, json: LibrarianWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Librarian.PubSub,
  live_view: [signing_salt: "JFYl/knN"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  librarian: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  librarian: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :librarian, :storage_path, System.get_env("STORAGE_PATH", "priv/data")

config :librarian, Oban,
  repo: Librarian.Repo,
  plugins: [
    Oban.Plugins.Pruner,
    Oban.Plugins.Lifeline,
    {Oban.Plugins.Cron,
     crontab: [
       {"*/10 * * * *", Librarian.Workers.ScheduleFeedsWorker},
       {"0 2 * * *", Librarian.Workers.BackupWorker},
       {"*/15 * * * *", Librarian.Workers.EmbedArticlesWorker},
       {"15 */2 * * *", Librarian.Workers.TagArticlesWorker},
       {"30 * * * *", Librarian.Workers.BuildGraphWorker},
       {"45 3 * * *", Librarian.Workers.DiscoverSourcesWorker},
       {"50 3 * * *", Librarian.Workers.PruneSourcesWorker}
     ]}
  ],
  queues: [feeds: 5, vault: 2, backup: 1, stream: 3]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
