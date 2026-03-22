defmodule KomunBackend.MixProject do
  use Mix.Project

  def project do
    [
      app: :komun_backend,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {KomunBackend.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # ── Phoenix core ────────────────────────────────────────────────────────
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.2"},
      {:gettext, "~> 1.0"},
      {:dns_cluster, "~> 0.2.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},

      # ── Auth ─────────────────────────────────────────────────────────────────
      {:guardian, "~> 2.3"},
      {:guardian_db, "~> 3.0"},
      {:bcrypt_elixir, "~> 3.0"},

      # ── Email ────────────────────────────────────────────────────────────────
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},

      # ── Background jobs ──────────────────────────────────────────────────────
      {:oban, "~> 2.18"},

      # ── Redis ────────────────────────────────────────────────────────────────
      {:redix, "~> 1.5"},

      # ── S3 / MinIO ───────────────────────────────────────────────────────────
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:hackney, "~> 1.18"},
      {:sweet_xml, "~> 0.7"},

      # ── CORS ─────────────────────────────────────────────────────────────────
      {:cors_plug, "~> 3.0"},

      # ── Utilities ────────────────────────────────────────────────────────────
      {:ecto_ulid, "~> 0.3"},

      # ── Dev / Test ───────────────────────────────────────────────────────────
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:ex_machina, "~> 2.8", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
