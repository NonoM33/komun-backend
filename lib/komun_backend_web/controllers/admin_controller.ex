defmodule KomunBackendWeb.AdminController do
  use KomunBackendWeb, :controller

  import Ecto.Query
  alias KomunBackend.{Accounts, Buildings, Repo}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Announcements.Announcement
  alias KomunBackend.Buildings.{Building, BuildingMember}
  alias KomunBackend.Chat.Message
  alias KomunBackend.Incidents.Incident
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

  # POST /api/v1/admin/users/:id/magic-link
  #
  # Génère un magic-link pour l'user cible SANS envoyer l'email et
  # renvoie l'URL complète au super_admin. Pensé pour le support : un
  # voisin dit "mon lien ne marche pas", l'admin lui génère un nouveau
  # lien et lui transmet manuellement (WhatsApp, SMS…). Conséquence du
  # fix d'invalidation : cette génération invalide tous les liens
  # précédents pour cet email (voir Accounts.create_magic_link).
  def generate_magic_link(conn, %{"id" => target_id}) do
    current = Guardian.Plug.current_resource(conn)

    case Accounts.get_user(target_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      target ->
        require Logger

        Logger.warning(
          "[admin:magic_link] admin=#{current.email}(#{current.id}) " <>
            "→ generated link for #{target.email}(#{target.id})"
        )

        case Accounts.create_magic_link(target.email) do
          {:ok, token} ->
            base = System.get_env("APP_BASE_URL", "https://komun.app")
            url = "#{base}/auth/verify?token=#{token}"

            json(conn, %{
              url: url,
              email: target.email,
              expires_in_minutes: 15
            })

          {:error, cs} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: Ecto.Changeset.traverse_errors(cs, &elem(&1, 0))})
        end
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
    actor = Guardian.Plug.current_resource(conn)

    with {:ok, role_atom} <- parse_role(role),
         {:ok, user} <-
           Accounts.update_user_role(id, role_atom,
             actor_id: actor && actor.id,
             source: :admin_panel
           ) do
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

  # POST /admin/buildings/:id/members
  #
  # Insertion stricte : 409 si la ligne existe déjà. Pour changer le
  # rôle d'un membre existant, utilisez PUT
  # `/admin/buildings/:id/members/:user_id/role` (cf. update_member_role/2).
  def add_member(conn, %{"id" => building_id, "user_id" => user_id, "role" => role}) do
    actor = Guardian.Plug.current_resource(conn)

    with {:ok, role_atom} <- parse_member_role(role),
         {:ok, _member} <-
           Buildings.add_member(building_id, user_id, role_atom,
             actor_id: actor && actor.id,
             source: :admin_panel
           ) do
      json(conn, %{message: "Member added"})
    else
      {:error, :already_member} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "already_member",
          hint: "Use PUT /admin/buildings/:id/members/:user_id/role to change the role."
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def add_member(conn, %{"id" => building_id, "user_email" => email}) do
    actor = Guardian.Plug.current_resource(conn)

    with user when not is_nil(user) <- Accounts.get_user_by_email(email),
         {:ok, _member} <-
           Buildings.add_member(building_id, user.id, :coproprietaire,
             actor_id: actor && actor.id,
             source: :admin_panel
           ) do
      json(conn, %{message: "Member added"})
    else
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      {:error, :already_member} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "already_member"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def add_member(conn, _), do: conn |> put_status(400) |> json(%{error: "user_id or user_email required"})

  # PUT /admin/buildings/:id/members/:user_id/role
  #
  # Met à jour explicitement le rôle d'un membre existant. 404 si le
  # membre n'existe pas dans ce bâtiment — c'est volontaire, le caller
  # doit faire un POST (insertion) pour ajouter quelqu'un.
  def update_member_role(conn, %{"id" => building_id, "user_id" => user_id, "role" => role}) do
    actor = Guardian.Plug.current_resource(conn)

    with {:ok, role_atom} <- parse_member_role(role),
         {:ok, member} <-
           Buildings.set_member_role(building_id, user_id, role_atom,
             actor_id: actor && actor.id,
             source: :admin_panel
           ) do
      json(conn, %{
        data: %{
          id: member.id,
          building_id: member.building_id,
          user_id: member.user_id,
          role: member.role
        }
      })
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Member not found in this building"})

      {:error, :invalid_role} ->
        conn |> put_status(422) |> json(%{error: "Invalid role"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def update_member_role(conn, _),
    do: conn |> put_status(400) |> json(%{error: "role is required"})

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
    actor = Guardian.Plug.current_resource(conn)

    case Buildings.remove_member(building_id, user_id,
           actor_id: actor && actor.id,
           source: :admin_panel
         ) do
      {:ok, _} -> json(conn, %{message: "Member removed"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
    end
  end

  # GET /api/v1/admin/analytics
  #
  # Aggregate KPIs for the admin dashboard. Counts are scoped to the whole
  # instance — we don't have a notion of "current organization" on the
  # Elixir backend yet, and super_admin is typically the only caller.
  #
  # Shape mirrors the old Rails endpoint so the frontend doesn't need to
  # change: overview + recent_activity + engagement.
  def analytics(conn, _params) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    seven_days_ago = DateTime.add(now, -7, :day)
    thirty_days_ago = DateTime.add(now, -30, :day)

    overview = %{
      residents_count: Repo.aggregate(from(u in User), :count, :id),
      pending_residents:
        Repo.aggregate(
          from(u in User,
            left_join: m in BuildingMember, on: m.user_id == u.id,
            where: is_nil(m.id)
          ),
          :count,
          :id
        ),
      buildings_count: Repo.aggregate(from(b in Building), :count, :id),
      posts_this_month:
        Repo.aggregate(
          from(a in Announcement, where: a.inserted_at >= ^thirty_days_ago),
          :count,
          :id
        ),
      active_incidents:
        Repo.aggregate(
          from(i in Incident, where: i.status in [:open, :in_progress]),
          :count,
          :id
        ),
      upcoming_events: 0,
      bookings_today: 0
    }

    engagement = %{
      active_users_7d:
        Repo.aggregate(
          from(u in User, where: u.last_sign_in_at >= ^seven_days_ago),
          :count,
          :id
        ),
      active_users_30d:
        Repo.aggregate(
          from(u in User, where: u.last_sign_in_at >= ^thirty_days_ago),
          :count,
          :id
        ),
      messages_7d:
        Repo.aggregate(
          from(m in Message, where: m.inserted_at >= ^seven_days_ago),
          :count,
          :id
        ),
      posts_7d:
        Repo.aggregate(
          from(a in Announcement, where: a.inserted_at >= ^seven_days_ago),
          :count,
          :id
        )
    }

    recent_incidents =
      Repo.all(
        from(i in Incident,
          order_by: [desc: i.inserted_at],
          limit: 3,
          preload: :reporter
        )
      )
      |> Enum.map(fn i ->
        %{
          type: "incident",
          title: i.title,
          status: i.status,
          author: reporter_name(i.reporter),
          created_at: i.inserted_at
        }
      end)

    recent_announcements =
      Repo.all(
        from(a in Announcement,
          order_by: [desc: a.inserted_at],
          limit: 3,
          preload: :author
        )
      )
      |> Enum.map(fn a ->
        %{
          type: "post",
          title: a.title,
          author: reporter_name(a.author),
          created_at: a.inserted_at
        }
      end)

    recent_activity =
      (recent_incidents ++ recent_announcements)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.take(10)

    json(conn, %{
      data: %{
        overview: overview,
        recent_activity: recent_activity,
        engagement: engagement
      }
    })
  end

  # GET /api/v1/admin/residents/pending — users registered but not yet
  # attached to a building. Matches the old Rails "à approuver" list.
  def pending_residents(conn, _params) do
    users =
      Repo.all(
        from(u in User,
          left_join: m in BuildingMember, on: m.user_id == u.id,
          where: is_nil(m.id),
          order_by: [desc: u.inserted_at]
        )
      )

    json(conn, %{
      data:
        Enum.map(users, fn u ->
          %{
            id: u.id,
            email: u.email,
            full_name: full_name(u),
            apartment_number: u.apartment_number,
            role: u.role,
            created_at: u.inserted_at
          }
        end)
    })
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

  defp reporter_name(%Ecto.Association.NotLoaded{}), do: nil
  defp reporter_name(nil), do: nil
  defp reporter_name(user), do: full_name(user)

  defp full_name(%{first_name: f, last_name: l}) when is_binary(f) and is_binary(l),
    do: "#{f} #{l}"
  defp full_name(%{first_name: f}) when is_binary(f), do: f
  defp full_name(%{email: e}) when is_binary(e), do: e
  defp full_name(_), do: nil
end
