defmodule KomunBackendWeb.AdminController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Accounts, Buildings}
  alias KomunBackend.Auth.Guardian

  def list_users(conn, _) do
    users = Accounts.list_users()
    json(conn, %{data: Enum.map(users, &user_json/1)})
  end

  # GET /api/v1/admin/users/:id — detailed view with memberships
  def show_user(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      user ->
        memberships =
          Buildings.list_user_buildings(user.id)
          |> Enum.map(fn {b, role} ->
            %{
              building: %{id: b.id, name: b.name, address: b.address, city: b.city},
              role: role
            }
          end)

        json(conn, %{
          data: Map.put(user_json(user), :memberships, memberships)
        })
    end
  end

  # POST /api/v1/admin/users/:id/impersonate
  #
  # Permet à un super_admin de se "connecter en tant que" un autre user.
  # On renvoie une paire de tokens JWT standards, enrichis d'un claim
  # `impersonated_by` qui contient l'id du super_admin initiateur. Le
  # frontend l'affiche via /me pour bannière + bouton "Revenir à mon
  # compte". Garde-fous :
  #
  # - super_admin ne peut pas s'impersonate lui-même
  # - impossible d'impersonate un autre super_admin (évite escalade /
  #   chain d'impersonation)
  # - journalisé dans les logs (Logger.warning) pour audit
  def impersonate(conn, %{"id" => target_id}) do
    current = Guardian.Plug.current_resource(conn)

    cond do
      to_string(current.id) == to_string(target_id) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Vous ne pouvez pas vous impersonate vous-même."})

      true ->
        case Accounts.get_user(target_id) do
          nil ->
            conn |> put_status(404) |> json(%{error: "User not found"})

          %{role: :super_admin} ->
            conn
            |> put_status(:forbidden)
            |> json(%{
              error:
                "Impossible d'impersonate un autre super_admin (évite les chaînes d'impersonation)."
            })

          target ->
            # Audit log : qui impersonate qui, quand, depuis quelle IP.
            remote_ip =
              case conn.remote_ip do
                {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
                _ -> "unknown"
              end

            require Logger

            Logger.warning(
              "[impersonate] admin=#{current.email}(#{current.id}) " <>
                "→ target=#{target.email}(#{target.id}) ip=#{remote_ip}"
            )

            claims = %{"impersonated_by" => to_string(current.id)}

            {:ok, access_token, _} =
              Guardian.encode_and_sign(target, claims, ttl: {1, :hour})

            {:ok, refresh_token, _} =
              Guardian.encode_and_sign(target, claims,
                token_type: "refresh",
                ttl: {30, :day}
              )

            json(conn, %{
              access_token: access_token,
              refresh_token: refresh_token,
              user: user_json(target),
              impersonated_by: %{
                id: current.id,
                email: current.email,
                first_name: current.first_name,
                last_name: current.last_name
              }
            })
        end
    end
  end

  # DELETE /api/v1/admin/users/:id — delete a user account.
  # Guardrails: a super_admin can't delete themselves (would lock out the
  # system), and we refuse to delete the hard-coded seed super_admin.
  def delete_user(conn, %{"id" => id}) do
    current = Guardian.Plug.current_resource(conn)

    cond do
      to_string(current.id) == to_string(id) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Impossible de supprimer votre propre compte."})

      true ->
        case Accounts.get_user(id) do
          nil ->
            conn |> put_status(404) |> json(%{error: "User not found"})

          %{email: "renaudlemagicien@gmail.com"} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Le super_admin de référence ne peut pas être supprimé."})

          user ->
            case Accounts.delete_user(user) do
              {:ok, _} -> send_resp(conn, :no_content, "")
              {:error, cs} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{errors: format_errors(cs)})
            end
        end
    end
  end

  def update_user_role(conn, %{"id" => id, "role" => role}) do
    with {:ok, role_atom} <- parse_role(role),
         {:ok, user} <- Accounts.update_user_role(id, role_atom) do
      json(conn, %{data: user_json(user)})
    else
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "User not found"})
      {:error, :invalid_role} -> conn |> put_status(422) |> json(%{error: "Invalid role"})
      {:error, changeset} -> conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_user_role(conn, _), do: conn |> put_status(400) |> json(%{error: "role is required"})

  def list_buildings(conn, _) do
    buildings = Buildings.list_all_buildings()
    json(conn, %{data: Enum.map(buildings, &building_json/1)})
  end

  def create_building(conn, params) do
    case Buildings.create_building(params) do
      {:ok, building} -> conn |> put_status(201) |> json(%{data: building_json(building)})
      {:error, changeset} -> conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def add_member(conn, %{"id" => building_id, "user_id" => user_id, "role" => role}) do
    with {:ok, role_atom} <- parse_member_role(role),
         {:ok, _member} <- Buildings.add_member(building_id, user_id, role_atom) do
      json(conn, %{message: "Member added"})
    else
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def add_member(conn, %{"id" => building_id, "user_email" => email}) do
    with user when not is_nil(user) <- Accounts.get_user_by_email(email),
         {:ok, _member} <- Buildings.add_member(building_id, user.id, :coproprietaire) do
      json(conn, %{message: "Member added"})
    else
      nil -> conn |> put_status(404) |> json(%{error: "User not found"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def add_member(conn, _), do: conn |> put_status(400) |> json(%{error: "user_id or user_email required"})

  # DELETE /admin/users/:id/onboarding — reset first_name/last_name to nil
  def reset_onboarding(conn, %{"id" => user_id}) do
    case Accounts.get_user(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})
      user ->
        case Accounts.update_user(user, %{first_name: nil, last_name: nil}) do
          {:ok, updated} -> json(conn, %{data: user_json(updated)})
          {:error, cs} -> conn |> put_status(422) |> json(%{errors: format_errors(cs)})
        end
    end
  end

  def remove_member(conn, %{"id" => building_id, "user_id" => user_id}) do
    case Buildings.remove_member(building_id, user_id) do
      {:ok, _} -> json(conn, %{message: "Member removed"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role,
      first_name: user.first_name,
      last_name: user.last_name,
      phone: user.phone,
      avatar_url: user.avatar_url,
      status: user.status,
      apartment_number: user.apartment_number,
      floor: user.floor,
      last_sign_in_at: user.last_sign_in_at,
      inserted_at: user.inserted_at
    }
  end

  defp building_json(b) do
    %{
      id: b.id,
      name: b.name,
      address: b.address,
      city: b.city,
      postal_code: b.postal_code
    }
  end

  defp parse_role(role) do
    valid = ~w(super_admin syndic_manager syndic_staff president_cs membre_cs coproprietaire locataire gardien prestataire)
    if role in valid, do: {:ok, String.to_atom(role)}, else: {:error, :invalid_role}
  end

  defp parse_member_role(role) do
    valid = ~w(president_cs membre_cs coproprietaire locataire gardien prestataire)
    if role in valid, do: {:ok, String.to_atom(role)}, else: {:error, :invalid_role}
  end

  defp format_errors(changeset) when is_struct(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
  defp format_errors(other), do: other
end
