import Config

# ── Database ──────────────────────────────────────────────────────────────────
config :komun_backend, KomunBackend.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "komun_backend_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# ── Endpoint ─────────────────────────────────────────────────────────────────
config :komun_backend, KomunBackendWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "z2mGK3jRWue4tnr3v/tbbY2WSpUsmnSBIsedIFxQaA+zt+4cef+VBY4tjYgLMbcc",
  watchers: []

# ── Guardian ──────────────────────────────────────────────────────────────────
config :komun_backend, KomunBackend.Auth.Guardian,
  secret_key: "dev_only_secret_change_in_prod_32chars_min"

# ── Oban (dev — inline for easy debugging) ───────────────────────────────────
config :komun_backend, Oban,
  testing: :inline

# ── Mailer (dev — Resend pour tester les vrais emails) ───────────────────────
config :komun_backend, KomunBackend.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY", "re_Qojc4RKg_DkBtDUi9SyeZM1cxcu8Bbd7n")

config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# ── Logger ────────────────────────────────────────────────────────────────────
config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
