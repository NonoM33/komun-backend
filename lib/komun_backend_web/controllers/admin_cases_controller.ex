defmodule KomunBackendWeb.AdminCasesController do
  @moduledoc """
  Endpoint d'ingestion **programmatique** de dossiers (incidents,
  doléances, diligences) — pensé pour qu'une IA externe (ChatGPT,
  Claude, agent custom…) puisse créer des dossiers en masse à partir
  d'emails / PDFs / notes manuelles préalablement classifiés par
  l'admin ou par l'IA elle-même.

  ## Pourquoi ce endpoint et pas le pipeline d'ingestion existant ?

  `POST /buildings/:id/ingestions/files` accepte du brut (eml/pdf/img)
  et lance Groq pour classifier. Quand l'admin a déjà fait le travail
  de classification (ou veut utiliser un autre LLM), il a besoin d'un
  endpoint qui accepte des **dossiers déjà structurés** et les insère
  directement, sans repasser par Groq. C'est ce que fait celui-ci.

  ## Auth

  - Pipeline `:require_super_admin` → seul un super_admin peut
    appeler. Les syndics passent par les endpoints de création
    standards (incidents/doléances/diligences).
  - Pas de gating par bâtiment supplémentaire : super_admin a accès
    à tous les bâtiments par définition.

  ## Garanties

  - **Tous les dossiers créés démarrent en `:brouillon`** —
    impossible de bypasser la validation humaine via cet endpoint
    (cf. règle imposée par le user le 2026-04-28).
  - **Reporter / créateur = l'utilisateur appelant** (super_admin),
    pas un compte « system » : tracable dans le role_audit_log et
    dans l'UI fiche détail.
  - **Pas d'IA déclenchée à la création** : `create_incident/3` du
    contexte Incidents lance normalement le triage Groq + les
    notifications voisinage. Pour les brouillons on **skip** ces
    side-effects (un dossier non validé ne doit pas notifier les
    voisins ni consommer du budget Groq). Voir gating dans le
    contexte.

  ## Format de requête

      POST /api/v1/admin/buildings/:building_id/cases/batch
      Authorization: Bearer <super_admin JWT>
      Content-Type: application/json

      {
        "cases": [
          {
            "type": "incident",
            "title": "Chauffage en panne hall A",
            "description": "Le chauffagiste n'a pas pu intervenir car pas de clé...",
            "category": "ascenseur" | "plomberie" | "electricite" | "ascenseur"
                        | "serrurerie" | "toiture" | "facades"
                        | "parties_communes" | "espaces_verts" | "autre",
            "severity": "low" | "medium" | "high" | "critical",
            "location": "Local technique RDC",
            "lot_number": "2108"
          },
          {
            "type": "doleance",
            "title": "Encombrants laissés sur le trottoir",
            "description": "Matelas et matériaux de bricolage abandonnés...",
            "category": "voirie_parking" | "structure" | "parties_communes" | …,
            "severity": "low" | "medium" | "high" | "critical",
            "target_kind": "syndic" | "constructor" | "insurance" | "authority" | "other"
          },
          {
            "type": "diligence",
            "title": "Nuisances olfactives lot 14",
            "description": "Odeurs de cannabis répétées...",
            "source_type": "copro_owner" | "tenant" | "unknown",
            "source_label": "M. Untel — lot 14"
          }
        ]
      }

  ## Format de réponse

      201 Created
      {
        "data": {
          "created": [
            { "index": 0, "type": "incident", "id": "uuid", "title": "...", "status": "brouillon" },
            { "index": 1, "type": "doleance", "id": "uuid", "title": "...", "status": "brouillon" },
            { "index": 2, "type": "diligence", "id": "uuid", "title": "...", "status": "brouillon" }
          ],
          "errors": []
        }
      }

  Les erreurs par dossier sont remontées sans bloquer les autres
  (best-effort). Une erreur globale (auth, building inexistant)
  retourne 4xx avec un body d'erreur classique.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Incidents, Doleances, Diligences}
  alias KomunBackend.Auth.Guardian

  @max_batch_size 50

  def batch(conn, %{"building_id" => building_id, "cases" => cases})
      when is_list(cases) do
    actor = Guardian.Plug.current_resource(conn)

    cond do
      length(cases) > @max_batch_size ->
        conn
        |> put_status(:payload_too_large)
        |> json(%{error: "max_batch_size_exceeded", limit: @max_batch_size})
        |> halt()

      not building_exists?(building_id) ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "building_not_found"})
        |> halt()

      true ->
        results =
          cases
          |> Enum.with_index()
          |> Enum.map(fn {case_attrs, idx} ->
            ingest_one(case_attrs, idx, building_id, actor)
          end)

        {created, errors} = Enum.split_with(results, &(elem(&1, 0) == :ok))

        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            created: Enum.map(created, fn {:ok, payload} -> payload end),
            errors: Enum.map(errors, fn {:error, payload} -> payload end)
          }
        })
    end
  end

  def batch(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_or_invalid_cases", hint: "Body must be {\"cases\": [...]} with a list."})
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp building_exists?(building_id) do
    Buildings.get_building!(building_id)
    true
  rescue
    Ecto.NoResultsError -> false
    Ecto.Query.CastError -> false
  end

  defp ingest_one(%{"type" => "incident"} = attrs, idx, building_id, actor) do
    payload =
      attrs
      |> Map.take([
        "title",
        "description",
        "category",
        "severity",
        "location",
        "lot_number",
        "visibility",
        "subtype"
      ])
      |> Map.put("status", "brouillon")
      |> default_if_missing("category", "autre")
      |> default_if_missing("severity", "medium")

    case Incidents.create_incident(building_id, actor.id, payload) do
      {:ok, incident} ->
        {:ok,
         %{
           index: idx,
           type: "incident",
           id: incident.id,
           title: incident.title,
           status: to_string(incident.status)
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, %{index: idx, type: "incident", errors: format_errors(cs)}}
    end
  end

  defp ingest_one(%{"type" => "doleance"} = attrs, idx, building_id, actor) do
    payload =
      attrs
      |> Map.take([
        "title",
        "description",
        "category",
        "severity",
        "target_kind",
        "target_name",
        "target_email"
      ])
      |> Map.put("status", "brouillon")
      |> default_if_missing("category", "autre")
      |> default_if_missing("severity", "medium")

    case Doleances.create_doleance(building_id, actor.id, payload) do
      {:ok, doleance} ->
        {:ok,
         %{
           index: idx,
           type: "doleance",
           id: doleance.id,
           title: doleance.title,
           status: to_string(doleance.status)
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, %{index: idx, type: "doleance", errors: format_errors(cs)}}
    end
  end

  defp ingest_one(%{"type" => "diligence"} = attrs, idx, building_id, actor) do
    payload =
      attrs
      |> Map.take([
        "title",
        "description",
        "source_type",
        "source_label",
        "linked_incident_id"
      ])
      |> Map.put("status", "brouillon")
      |> default_if_missing("source_type", "unknown")

    case Diligences.create_diligence(building_id, actor, payload) do
      {:ok, diligence} ->
        {:ok,
         %{
           index: idx,
           type: "diligence",
           id: diligence.id,
           title: diligence.title,
           status: to_string(diligence.status)
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, %{index: idx, type: "diligence", errors: format_errors(cs)}}
    end
  end

  defp ingest_one(other, idx, _building_id, _actor) do
    type = Map.get(other, "type", "(missing)")

    {:error,
     %{
       index: idx,
       error: "invalid_type",
       hint: "type must be one of: incident, doleance, diligence",
       received: type
     }}
  end

  defp default_if_missing(map, key, default) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, default)
      "" -> Map.put(map, key, default)
      _ -> map
    end
  end

  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
  end
end
