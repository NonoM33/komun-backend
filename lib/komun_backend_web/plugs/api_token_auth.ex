defmodule KomunBackendWeb.Plugs.ApiTokenAuth do
  @moduledoc """
  Authentification par Personal Access Token (PAT).

  Si l'`Authorization` header contient un token au format
  `kmn_pat_<...>`, ce plug le valide via `KomunBackend.Auth.ApiTokens`
  et hydrate le `Guardian.Plug` (token + claims + resource) comme
  l'aurait fait un JWT.

  - Token valide : la pipeline Guardian qui suit voit déjà un
    `current_token`, donc `VerifyHeader` ne fait rien et
    `EnsureAuthenticated` passe naturellement.
  - Token au préfixe `kmn_pat_` mais invalide / révoqué / expiré :
    on renvoie 401 immédiatement (pas de fallback JWT — l'intention
    était claire).
  - Pas d'API token (header absent ou JWT classique) : on ne fait
    rien et on laisse la suite de la pipeline gérer.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias KomunBackend.Auth.ApiTokens

  @prefix "kmn_pat_"

  def init(opts), do: opts

  def call(conn, _opts) do
    case fetch_api_token(conn) do
      {:ok, plaintext} ->
        case ApiTokens.authenticate(plaintext) do
          {:ok, user} ->
            conn
            |> Guardian.Plug.put_current_token(plaintext)
            |> Guardian.Plug.put_current_claims(%{
              "sub" => user.id,
              "auth_method" => "api_token"
            })
            |> Guardian.Plug.put_current_resource(user)

          {:error, _reason} ->
            conn
            |> put_status(401)
            |> json(%{error: "invalid_api_token"})
            |> halt()
        end

      :no_api_token ->
        conn
    end
  end

  defp fetch_api_token(conn) do
    with [auth_header | _] <- get_req_header(conn, "authorization"),
         trimmed <- String.trim(auth_header),
         %{"token" => token} <-
           Regex.named_captures(~r/^[Bb]earer\s+(?<token>.+)$/, trimmed),
         token <- String.trim(token),
         true <- String.starts_with?(token, @prefix) do
      {:ok, token}
    else
      _ -> :no_api_token
    end
  end
end
