defmodule KomunBackendWeb.UserController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Accounts, Auth.Guardian}

  def me(conn, _) do
    user = Guardian.Plug.current_resource(conn)

    # Si la session courante est une impersonation, on expose l'admin
    # initiateur pour que le frontend affiche la bannière "Vous êtes
    # connecté en tant que X — [Revenir]".
    claims = Guardian.Plug.current_claims(conn) || %{}

    impersonator =
      case Map.get(claims, "impersonated_by") do
        admin_id when is_binary(admin_id) and admin_id != "" ->
          case Accounts.get_user(admin_id) do
            nil ->
              nil

            admin ->
              %{
                id: admin.id,
                email: admin.email,
                first_name: admin.first_name,
                last_name: admin.last_name
              }
          end

        _ ->
          nil
      end

    json(conn, %{
      data: Map.put(user_json(user), :impersonated_by, impersonator)
    })
  end

  def update_profile(conn, %{"user" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    case Accounts.update_user(user, attrs) do
      {:ok, updated} -> json(conn, %{data: user_json(updated)})
      {:error, cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(cs, &elem(&1, 0))})
    end
  end

  defp user_json(u), do: %{
    id: u.id,
    email: u.email,
    role: u.role,
    first_name: u.first_name,
    last_name: u.last_name,
    phone: u.phone,
    avatar_url: u.avatar_url,
    locale: u.locale,
    status: u.status,
    apartment_number: u.apartment_number,
    floor: u.floor,
    inserted_at: u.inserted_at
  }
end
