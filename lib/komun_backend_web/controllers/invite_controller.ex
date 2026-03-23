defmodule KomunBackendWeb.InviteController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Buildings

  # ── POST /api/v1/buildings/:building_id/invites ────────────────────────────
  # Crée une invitation. Requiert d'être authentifié et membre privilegié.
  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    # Vérifier que le user a le droit (admin, president_cs, syndic_*)
    role = Buildings.get_member_role(building_id, user.id)

    unless user.role == :super_admin or role in [:president_cs, :syndic_manager, :syndic_staff] do
      conn
      |> put_status(403)
      |> json(%{error: "Not authorized to create invites for this building"})
      |> halt()
    else
      opts = []
      opts = if params["role"], do: Keyword.put(opts, :role, params["role"]), else: opts
      opts = if params["max_uses"], do: Keyword.put(opts, :max_uses, params["max_uses"]), else: opts
      opts = if params["expires_in_days"], do: Keyword.put(opts, :expires_in_days, params["expires_in_days"]), else: opts

      case Buildings.create_invite(building_id, user.id, opts) do
        {:ok, invite} ->
          conn
          |> put_status(201)
          |> json(%{data: invite_json(invite)})

        {:error, changeset} ->
          conn
          |> put_status(422)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  # ── GET /api/v1/invites/:token ─────────────────────────────────────────────
  # Informations publiques sur une invite (pas d'auth requise).
  def show(conn, %{"token" => token}) do
    case Buildings.get_invite_by_token(token) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Invite not found or expired"})

      invite ->
        json(conn, %{data: %{
          token: invite.token,
          role: invite.role,
          building: %{
            id: invite.building.id,
            name: invite.building.name,
            address: invite.building.address,
            city: invite.building.city
          }
        }})
    end
  end

  # ── POST /api/v1/invites/:token/join ──────────────────────────────────────
  # Rejoindre un immeuble via une invite. Requiert d'être authentifié.
  def join(conn, %{"token" => token}) do
    user = Guardian.Plug.current_resource(conn)

    case Buildings.get_invite_by_token(token) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Invite not found or expired"})

      invite ->
        # Vérifier si déjà membre
        if Buildings.member?(invite.building_id, user.id) do
          conn |> put_status(200) |> json(%{
            message: "Already a member",
            building_id: invite.building_id
          })
        else
          case Buildings.use_invite(invite, user.id) do
            {:ok, _member} ->
              json(conn, %{
                message: "Joined successfully",
                building_id: invite.building_id,
                role: invite.role
              })

            {:error, reason} ->
              conn
              |> put_status(422)
              |> json(%{error: inspect(reason)})
          end
        end
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp invite_json(invite) do
    %{
      id: invite.id,
      token: invite.token,
      role: invite.role,
      used_count: invite.used_count,
      max_uses: invite.max_uses,
      expires_at: invite.expires_at,
      is_active: invite.is_active,
      building_id: invite.building_id
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
