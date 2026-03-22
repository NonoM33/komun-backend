defmodule KomunBackendWeb.UserController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Accounts, Auth.Guardian}

  def me(conn, _) do
    user = Guardian.Plug.current_resource(conn)
    json(conn, %{data: user_json(user)})
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
    inserted_at: u.inserted_at
  }
end
