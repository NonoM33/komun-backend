defmodule KomunBackend.Auth.Pipeline do
  use Guardian.Plug.Pipeline,
    otp_app: :komun_backend,
    module: KomunBackend.Auth.Guardian,
    error_handler: KomunBackend.Auth.ErrorHandler

  # Verify the JWT from Authorization: Bearer <token>
  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource, allow_blank: false
end
