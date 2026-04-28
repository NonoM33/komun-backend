defmodule KomunBackend.Auth.Pipeline do
  use Guardian.Plug.Pipeline,
    otp_app: :komun_backend,
    module: KomunBackend.Auth.Guardian,
    error_handler: KomunBackend.Auth.ErrorHandler

  # Auth par Personal Access Token : si l'`Authorization` header
  # contient un `kmn_pat_<...>`, ce plug hydrate le conn comme
  # le ferait Guardian, et la suite de la pipeline ne fait rien.
  plug KomunBackendWeb.Plugs.ApiTokenAuth

  # Verify the JWT from Authorization: Bearer <token>
  plug Guardian.Plug.VerifyHeader, scheme: "Bearer"
  plug Guardian.Plug.EnsureAuthenticated
  plug Guardian.Plug.LoadResource, allow_blank: false
end
