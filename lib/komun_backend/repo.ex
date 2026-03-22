defmodule KomunBackend.Repo do
  use Ecto.Repo,
    otp_app: :komun_backend,
    adapter: Ecto.Adapters.Postgres
end
