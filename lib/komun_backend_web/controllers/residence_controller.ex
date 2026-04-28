defmodule KomunBackendWeb.ResidenceController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Residences
  alias KomunBackend.Residences.Residence
  alias KomunBackend.{Doleances, Incidents}

  @privileged_roles [:president_cs, :membre_cs, :syndic_manager, :syndic_staff, :council]

  # ── Listing ────────────────────────────────────────────────────────────────

  # GET /api/v1/residences  (authentifié)
  # Retourne les résidences de l'utilisateur courant, avec les bâtiments
  # rattachés. Super admin voit tout.
  def index(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    residences =
      if user.role == :super_admin do
        Residences.list_all_residences()
      else
        Residences.list_user_residences(user.id)
      end

    json(conn, %{data: Enum.map(residences, &residence_json(&1, user))})
  end

  # GET /api/v1/residences/:id
  def show(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      residence ->
        residence = KomunBackend.Repo.preload(residence, :buildings)
        json(conn, %{data: residence_json(residence, user)})
    end
  end

  # ── Public verify (résidence OU bâtiment) ─────────────────────────────────
  #
  # GET /api/v1/codes/verify?code=XXXXXXXX
  #
  # Une route publique unifiée : on donne un code à la page d'inscription
  # sans savoir si c'est un code résidence ou bâtiment, le backend tranche.
  def verify_code(conn, %{"code" => code}) when is_binary(code) and code != "" do
    case Residences.verify_code(code) do
      {:residence, residence, buildings} ->
        # Placeholder-filter : on cache les bâtiments qui portent le même
        # nom que la résidence. Ce sont quasiment toujours des artefacts
        # de la migration auto-résidence (un building a été auto-promu
        # en résidence du même nom, puis d'autres bâtiments lui ont été
        # rattachés). À l'inscription, le voisin ne doit voir QUE les
        # bâtiments réels. Cas limite préservé : résidence mono-bâtiment
        # où le building s'appelle effectivement comme la résidence —
        # dans ce cas on ne filtre pas pour éviter de montrer une liste
        # vide (rien à choisir).
        displayable =
          if length(buildings) > 1 do
            residence_name_norm = normalize_name(residence.name)

            filtered =
              Enum.reject(buildings, fn b ->
                normalize_name(b.name) == residence_name_norm
              end)

            if filtered == [], do: buildings, else: filtered
          else
            buildings
          end

        json(conn, %{
          valid: true,
          type: "residence",
          residence: residence_summary(residence),
          buildings:
            Enum.map(displayable, fn b ->
              %{
                id: b.id,
                name: b.name,
                address: b.address,
                city: b.city,
                postal_code: b.postal_code,
                lot_count: b.lot_count
              }
            end)
        })

      {:building, building, residence} ->
        json(conn, %{
          valid: true,
          type: "building",
          building: %{
            id: building.id,
            name: building.name,
            address: building.address,
            city: building.city,
            postal_code: building.postal_code,
            lot_count: building.lot_count
          },
          residence: if(residence, do: residence_summary(residence), else: nil)
        })

      :not_found ->
        conn
        |> put_status(:not_found)
        |> json(%{valid: false, error: "invalid_code"})
    end
  end

  def verify_code(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{valid: false, error: "missing_code"})
  end

  # ── Create / update (admin ou CS) ─────────────────────────────────────────

  def create(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or user.role in @privileged_roles do
      case Residences.create_residence(params) do
        {:ok, residence} ->
          conn
          |> put_status(:created)
          |> json(%{data: residence_json(residence, user)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      %Residence{} = residence ->
        if authorized_for?(user, residence) do
          attrs = Map.drop(params, ["id"])

          case Residences.update_residence(residence, attrs) do
            {:ok, updated} -> json(conn, %{data: residence_json(updated, user)})
            {:error, cs} ->
              conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  # DELETE /api/v1/residences/:id
  # Soft-delete : on marque is_active=false. On refuse si la résidence
  # contient encore des bâtiments actifs pour éviter de rendre des
  # bâtiments orphelins sans prévenir.
  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      %Residence{} = residence ->
        if authorized_for?(user, residence) do
          residence = KomunBackend.Repo.preload(residence, :buildings)
          active_buildings = Enum.filter(residence.buildings, & &1.is_active)

          cond do
            length(active_buildings) > 0 ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{
                error: "not_empty",
                message:
                  "Cette résidence contient encore des bâtiments. " <>
                    "Déplacez-les avant de supprimer la résidence."
              })

            true ->
              case Residences.delete_residence(residence) do
                {:ok, _} -> json(conn, %{ok: true})
                {:error, cs} ->
                  conn
                  |> put_status(:unprocessable_entity)
                  |> json(%{errors: format_errors(cs)})
              end
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  # GET /api/v1/residences/:id/members
  # Liste tous les membres de la résidence (agrégation cross-buildings,
  # dédupliquée par user, avec le rôle le plus privilégié). Pensé pour
  # la page "Voisins" du front : montre tous les voisins de la copro,
  # pas seulement ceux du bâtiment courant du viewer (permet à un
  # copro de Batiment A de voir le président du CS qui est dans Batiment B).
  def members(conn, %{"id" => residence_id}) do
    case Residences.get_residence(residence_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      _residence ->
        members = Residences.list_residence_members(residence_id)

        json(conn, %{
          data:
            Enum.map(members, fn m ->
              %{
                id: m.id,
                role: m.role,
                joined_at: m.joined_at,
                building_id: m.building_id,
                user: %{
                  id: m.user.id,
                  email: m.user.email,
                  first_name: m.user.first_name,
                  last_name: m.user.last_name,
                  avatar_url: m.user.avatar_url,
                  phone: m.user.phone
                }
              }
            end)
        })
    end
  end

  # GET /api/v1/residences/:residence_id/users/:user_id/incidents
  # Liste les incidents signalés par `user_id` sur tous les bâtiments
  # de la résidence. Réservé au conseil / syndic / super_admin, ou à
  # l'utilisateur lui-même (self-view). Confidentialité préservée :
  # les incidents `:council_only` ne sortent pas de cette liste sauf
  # si le viewer est le reporter — sinon les agréger sous un user_id
  # explicite reviendrait à dévoiler l'auteur.
  def user_incidents(conn, %{"residence_id" => residence_id, "user_id" => user_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(residence_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      _residence ->
        if can_view_user_activity?(user, residence_id, user_id) do
          incidents = Incidents.list_user_incidents_in_residence(residence_id, user_id, user)
          json(conn, %{data: Enum.map(incidents, &user_incident_json/1)})
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  # GET /api/v1/residences/:residence_id/users/:user_id/doleances
  def user_doleances(conn, %{"residence_id" => residence_id, "user_id" => user_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(residence_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      _residence ->
        if can_view_user_activity?(user, residence_id, user_id) do
          doleances = Doleances.list_user_doleances_in_residence(residence_id, user_id, user)
          json(conn, %{data: Enum.map(doleances, &user_doleance_json/1)})
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  defp can_view_user_activity?(nil, _residence_id, _user_id), do: false

  defp can_view_user_activity?(%{id: viewer_id} = user, residence_id, target_user_id) do
    to_string(viewer_id) == to_string(target_user_id) or
      Residences.privileged_member?(residence_id, user)
  end

  # POST /api/v1/residences/:id/merge
  # Body: %{"source_ids" => ["uuid1", "uuid2", ...]}
  #
  # Absorbe toutes les résidences sources dans la résidence courante :
  # déplace leurs bâtiments, puis soft-delete les sources. Utile quand la
  # migration a auto-créé une résidence par bâtiment et qu'on veut tout
  # regrouper sous une seule copropriété.
  def merge(conn, %{"id" => target_id, "source_ids" => source_ids})
      when is_list(source_ids) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(target_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      %Residence{} = residence ->
        if authorized_for?(user, residence) do
          case Residences.merge_into(target_id, source_ids) do
            {:ok, stats} ->
              residence = KomunBackend.Repo.preload(residence, :buildings, force: true)

              json(conn, %{
                data: residence_json(residence, user),
                merged: stats
              })

            {:error, reason} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: inspect(reason)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  def merge(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "source_ids required"})

  # POST /api/v1/residences/:id/buildings/:building_id/attach
  def attach_building(conn, %{"id" => residence_id, "building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    case Residences.get_residence(residence_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "residence_not_found"})

      %Residence{} = residence ->
        if authorized_for?(user, residence) do
          case Residences.attach_building(residence.id, building_id) do
            {:ok, _building} ->
              residence = KomunBackend.Repo.preload(residence, :buildings, force: true)
              json(conn, %{data: residence_json(residence, user)})

            {:error, :not_found} ->
              conn |> put_status(:not_found) |> json(%{error: "building_not_found"})

            {:error, cs} ->
              conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
          end
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp authorized_for?(user, _residence) do
    # Pour l'instant : super_admin + rôles CS/syndic. Le scoping "seulement
    # les résidences où l'user a vraiment un rôle" viendra quand on aura
    # besoin de passer du CS d'une résidence à une autre (multi-copro).
    user.role == :super_admin or user.role in @privileged_roles
  end

  defp residence_json(%Residence{} = r, user) do
    buildings =
      case r.buildings do
        %Ecto.Association.NotLoaded{} -> []
        list when is_list(list) -> list
      end

    base = %{
      id: r.id,
      name: r.name,
      slug: r.slug,
      address: r.address,
      city: r.city,
      postal_code: r.postal_code,
      country: r.country,
      cover_url: r.cover_url,
      organization_id: r.organization_id,
      is_active: r.is_active,
      buildings:
        buildings
        |> Enum.filter(& &1.is_active)
        |> Enum.map(&building_json(&1, user))
    }

    if user.role == :super_admin or user.role in @privileged_roles do
      Map.put(base, :join_code, r.join_code)
    else
      base
    end
  end

  # Normalise un nom pour comparer building <-> residence : lowercase +
  # trim + collapse des espaces. Suffisant pour attraper les cas courants
  # ("unissons" vs " Unissons ").
  defp normalize_name(nil), do: ""

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp residence_summary(%Residence{} = r) do
    %{
      id: r.id,
      name: r.name,
      address: r.address,
      city: r.city,
      postal_code: r.postal_code
    }
  end

  defp building_json(b, user) do
    base = %{
      id: b.id,
      name: b.name,
      address: b.address,
      city: b.city,
      postal_code: b.postal_code,
      lot_count: b.lot_count,
      cover_url: b.cover_url
    }

    if user.role == :super_admin or user.role in @privileged_roles do
      Map.put(base, :join_code, b.join_code)
    else
      base
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  # ── Slim JSON pour la fiche voisin ─────────────────────────────────────
  # On ne renvoie que ce dont la fiche front a besoin pour lister
  # l'activité (id, titre, statut, sévérité, catégorie, building_id,
  # date). Pas de description, pas de commentaires, pas de fichiers,
  # pas de `reporter`/`author` — l'identité est connue du caller (c'est
  # lui qui a fourni `user_id`), inutile de la dupliquer dans chaque
  # entrée et de gonfler le payload.

  defp user_incident_json(inc) do
    %{
      id: inc.id,
      title: inc.title,
      category: inc.category,
      severity: inc.severity,
      status: inc.status,
      building_id: inc.building_id,
      visibility: inc.visibility,
      inserted_at: inc.inserted_at,
      resolved_at: inc.resolved_at
    }
  end

  defp user_doleance_json(d) do
    %{
      id: d.id,
      title: d.title,
      category: d.category,
      severity: d.severity,
      status: d.status,
      building_id: d.building_id,
      inserted_at: d.inserted_at,
      resolved_at: d.resolved_at
    }
  end
end
