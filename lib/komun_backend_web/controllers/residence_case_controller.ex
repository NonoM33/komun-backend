defmodule KomunBackendWeb.ResidenceCaseController do
  @moduledoc """
  Endpoints de gestion de dossiers (incident / doléance / diligence)
  rattachés à la résidence entière au lieu d'un bâtiment précis. Sert
  surtout à la routine d'ingestion email : quand un email parle d'un
  sujet transverse (« vice de construction commun aux deux bâtiments »,
  « voirie de la résidence »…), Claude POST ici plutôt que sur un
  bâtiment particulier.

  Routes :

    * `POST   /api/v1/residences/:residence_id/incidents`   → créer incident résidence
    * `POST   /api/v1/residences/:residence_id/doleances`   → créer doléance résidence
    * `POST   /api/v1/residences/:residence_id/diligences`  → créer diligence résidence
    * `PUT    /api/v1/residences/:residence_id/doleances/:id` → éditer doléance résidence
    * `DELETE /api/v1/residences/:residence_id/doleances/:id` → supprimer doléance résidence

  ## Authorization

  Pour la **création** :

    * `super_admin` (rôle global) → toujours autorisé
    * Pour incidents et doléances : tout user membre d'au moins un
      bâtiment de la résidence est autorisé (un copro peut soulever un
      sujet transverse).
    * Pour diligences : seuls les rôles privilégiés (syndic_manager /
      syndic_staff / president_cs / membre_cs / super_admin), comme
      au niveau bâtiment.

  Pour l'**édition / suppression** d'une doléance résidence : auteur de
  la doléance, super_admin, ou rôle privilégié (User.role syndic_* OU
  BuildingMember.role président_cs / membre_cs dans **n'importe quel
  bâtiment de la résidence**). Aligné sur la règle building-scope :
  un copro lambda peut éditer/supprimer sa propre doléance, et le
  syndic / CS peut intervenir sur toutes.

  Le check building-scope existant côté `IncidentController` /
  `DoleanceController` / `DiligenceController` reste tel quel pour les
  routes `/buildings/:bid/...`. Ce module ajoute uniquement le scope
  résidence.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Diligences, Doleances, Incidents, Residences, Repo}
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.BuildingMember
  import Ecto.Query

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # Sous-ensemble qui correspond aux valeurs de l'enum
  # `BuildingMember.role` — `:super_admin` / `:syndic_*` sont des
  # User.role globaux, pas des rôles côté BuildingMember.
  @privileged_member_roles [:president_cs, :membre_cs]

  # POST /api/v1/residences/:residence_id/incidents
  def create_incident(conn, %{"residence_id" => residence_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "incident", %{})

    with :ok <- authorize_member(conn, residence_id, user),
         {:ok, incident} <- Incidents.create_residence_incident(residence_id, user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize_incident(incident)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # POST /api/v1/residences/:residence_id/doleances
  def create_doleance(conn, %{"residence_id" => residence_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "doleance", %{})

    with :ok <- authorize_member(conn, residence_id, user),
         {:ok, doleance} <- Doleances.create_residence_doleance(residence_id, user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize_doleance(doleance)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # PUT /api/v1/residences/:residence_id/doleances/:id
  def update_doleance(conn, %{"residence_id" => residence_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "doleance", %{})

    with :ok <- authorize_member(conn, residence_id, user),
         {:ok, doleance} <- fetch_residence_doleance(conn, residence_id, id),
         :ok <- authorize_doleance_actor(conn, residence_id, user, doleance),
         {:ok, updated} <- Doleances.update_doleance(doleance, attrs, user.id) do
      json(conn, %{data: serialize_doleance(updated)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # DELETE /api/v1/residences/:residence_id/doleances/:id
  def delete_doleance(conn, %{"residence_id" => residence_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, residence_id, user),
         {:ok, doleance} <- fetch_residence_doleance(conn, residence_id, id),
         :ok <- authorize_doleance_actor(conn, residence_id, user, doleance),
         {:ok, _} <- Doleances.delete_doleance(doleance) do
      send_resp(conn, :no_content, "")
    else
      %Plug.Conn{} = halted ->
        halted
    end
  end

  # POST /api/v1/residences/:residence_id/diligences
  def create_diligence(conn, %{"residence_id" => residence_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "diligence", %{})

    with :ok <- authorize_privileged_for_residence(conn, residence_id, user),
         {:ok, diligence} <- Diligences.create_residence_diligence(residence_id, user, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: serialize_diligence(diligence)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # ── Authorization ──────────────────────────────────────────────────────

  defp authorize_member(conn, residence_id, user) do
    cond do
      is_nil(Residences.get_residence(residence_id)) ->
        conn |> put_status(:not_found) |> json(%{error: "Résidence introuvable"}) |> halt()

      user.role == :super_admin ->
        :ok

      member_of_residence?(residence_id, user.id) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Vous n'êtes membre d'aucun bâtiment de cette résidence"})
        |> halt()
    end
  end

  defp authorize_privileged_for_residence(conn, residence_id, user) do
    cond do
      is_nil(Residences.get_residence(residence_id)) ->
        conn |> put_status(:not_found) |> json(%{error: "Résidence introuvable"}) |> halt()

      user.role == :super_admin ->
        :ok

      user.role in @privileged_roles ->
        :ok

      privileged_member_of_residence?(residence_id, user.id) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Réservé au syndic et au conseil syndical"})
        |> halt()
    end
  end

  defp member_of_residence?(residence_id, user_id) do
    Repo.exists?(
      from bm in BuildingMember,
        join: b in assoc(bm, :building),
        where: b.residence_id == ^residence_id and bm.user_id == ^user_id
    )
  end

  defp privileged_member_of_residence?(residence_id, user_id) do
    Repo.exists?(
      from bm in BuildingMember,
        join: b in assoc(bm, :building),
        where:
          b.residence_id == ^residence_id and bm.user_id == ^user_id and
            bm.role in ^@privileged_member_roles
    )
  end

  # Fetch a doléance and assert it belongs to the requested residence.
  # Renvoie {:ok, doleance} ou halte la conn avec un 404 — utile pour
  # éviter qu'un user de la résidence A puisse supprimer une doléance
  # qui appartient à la résidence B en devinant son UUID.
  defp fetch_residence_doleance(conn, residence_id, doleance_id) do
    case Doleances.get_doleance(doleance_id) do
      %{residence_id: ^residence_id} = d ->
        {:ok, d}

      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Doléance introuvable dans cette résidence"})
        |> halt()
    end
  end

  # Update / delete d'une doléance résidence : autorisés à l'auteur, aux
  # super_admins, aux User.role privilégiés, et aux BuildingMember
  # président/membre du CS de n'importe quel bâtiment de la résidence.
  defp authorize_doleance_actor(conn, residence_id, user, doleance) do
    cond do
      to_string(doleance.author_id) == to_string(user.id) ->
        :ok

      user.role == :super_admin ->
        :ok

      user.role in @privileged_roles ->
        :ok

      privileged_member_of_residence?(residence_id, user.id) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seul l'auteur ou le conseil / syndic peut modifier cette doléance."})
        |> halt()
    end
  end

  # ── Serializers — slim payloads ─────────────────────────────────────────

  defp serialize_incident(inc) do
    %{
      id: inc.id,
      title: inc.title,
      description: inc.description,
      category: inc.category,
      severity: inc.severity,
      status: inc.status,
      residence_id: inc.residence_id,
      building_id: inc.building_id,
      reporter_id: inc.reporter_id,
      ai_ingestion_metadata: inc.ai_ingestion_metadata,
      inserted_at: inc.inserted_at,
      updated_at: inc.updated_at
    }
  end

  defp serialize_doleance(d) do
    %{
      id: d.id,
      title: d.title,
      description: d.description,
      category: d.category,
      status: d.status,
      residence_id: d.residence_id,
      building_id: d.building_id,
      author_id: d.author_id,
      target_kind: d.target_kind,
      ai_ingestion_metadata: d.ai_ingestion_metadata,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  defp serialize_diligence(d) do
    %{
      id: d.id,
      title: d.title,
      description: d.description,
      status: d.status,
      source_type: d.source_type,
      source_label: d.source_label,
      residence_id: d.residence_id,
      building_id: d.building_id,
      created_by_id: d.created_by_id,
      ai_ingestion_metadata: d.ai_ingestion_metadata,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  # Shared error formatter — mirrors the one in the building-scoped
  # controllers so client code can parse identically.
  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
