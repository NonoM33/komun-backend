defmodule KomunBackendWeb.ApiTokenController do
  @moduledoc """
  CRUD des Personal Access Tokens du conseil syndical / syndic.

  Endpoints (montés sous `/api/v1/me/api-tokens`) :

    * `GET    /` — liste des tokens de l'utilisateur courant
    * `POST   /` — création d'un token (le clair n'est renvoyé QU'ICI)
    * `DELETE /:id` — révocation

  Seuls les rôles autorisés (cf. `KomunBackend.Auth.ApiTokens.allowed_roles/0`)
  peuvent créer un token. Tout utilisateur authentifié peut en
  revanche lister / révoquer les siens — utile s'il a été
  rétrogradé et qu'il faut nettoyer un PAT actif.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Auth.{ApiToken, ApiTokens}

  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    tokens = ApiTokens.list_user_tokens(user.id)
    json(conn, %{data: Enum.map(tokens, &token_json/1)})
  end

  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.take(params, ["name", "expires_at"])

    case ApiTokens.create_token(user, attrs) do
      {:ok, %{api_token: api_token, plaintext: plaintext}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: token_json(api_token) |> Map.put(:token, plaintext)
        })

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seuls le syndic et le conseil syndical peuvent créer un token API."})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case ApiTokens.get_user_token(user.id, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Token introuvable"})

      %ApiToken{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        conn |> put_status(:gone) |> json(%{error: "Token déjà révoqué"})

      %ApiToken{} = token ->
        case ApiTokens.revoke_token(token) do
          {:ok, updated} -> json(conn, %{data: token_json(updated)})
          {:error, cs} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_errors(cs)})
        end
    end
  end

  defp token_json(%ApiToken{} = t) do
    %{
      id: t.id,
      name: t.name,
      token_prefix: t.token_prefix,
      last_used_at: t.last_used_at,
      expires_at: t.expires_at,
      revoked_at: t.revoked_at,
      inserted_at: t.inserted_at
    }
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
