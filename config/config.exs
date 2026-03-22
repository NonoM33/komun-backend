import Config

# ── Application ──────────────────────────────────────────────────────────────
config :komun_backend,
  ecto_repos: [KomunBackend.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# ── Endpoint ─────────────────────────────────────────────────────────────────
config :komun_backend, KomunBackendWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: KomunBackendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: KomunBackend.PubSub,
  live_view: [signing_salt: "RUnOIRMB"]

# ── Guardian JWT ──────────────────────────────────────────────────────────────
config :komun_backend, KomunBackend.Auth.Guardian,
  issuer: "komun",
  ttl: {1, :hour},
  allowed_drift: 2000,
  secret_key: System.get_env("GUARDIAN_SECRET_KEY", "dev_secret_change_in_prod")

# ── Oban background jobs ──────────────────────────────────────────────────────
config :komun_backend, Oban,
  repo: KomunBackend.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [
    default: 10,
    emails: 20,
    push_notifications: 30,
    pdf: 5
  ]

# ── Swoosh mailer ─────────────────────────────────────────────────────────────
config :komun_backend, KomunBackend.Mailer, adapter: Swoosh.Adapters.Local

# ── ExAws (S3 / MinIO) ───────────────────────────────────────────────────────
config :ex_aws,
  access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
  secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin"),
  s3: [
    scheme: "http://",
    host: System.get_env("MINIO_HOST", "localhost"),
    port: 9000
  ]

config :ex_aws, :s3,
  bucket: System.get_env("MINIO_BUCKET", "komun")

# ── Logger ────────────────────────────────────────────────────────────────────
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
