import Config

config :komun_backend, KomunBackend.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "komun_backend_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :komun_backend, KomunBackendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "r3/wmRTDFwgjPVRUkugVbRezLZ56ofYh8RNgCL6IxptQ3FFKlbM1mwOq1shT1UYK",
  server: false

config :komun_backend, KomunBackend.Auth.Guardian,
  secret_key: "test_guardian_secret_key_at_least_32chars"

config :komun_backend, Oban, testing: :inline

# Les battles utilisent un job Oban schedulé à `ends_at` (J+3 par
# défaut). En test, Oban `:inline` ignore `scheduled_at` et exécuterait
# immédiatement la transition de round, ce qui rend le cycle non
# testable. On bypass le scheduling : les tests appellent
# `Battles.advance_battle!/1` directement.
config :komun_backend, :skip_battle_scheduling, true

config :komun_backend, KomunBackend.Mailer, adapter: Swoosh.Adapters.Test

config :swoosh, :api_client, false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true
