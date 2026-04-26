defmodule KomunBackendWeb.IncidentEmailController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Incidents}
  alias KomunBackend.Incidents.{IncidentEmail, Emails, EmailAddressing}
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # GET /api/v1/incidents/:incident_id/emails
  def index(conn, %{"incident_id" => incident_id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, incident} <- fetch_authorized_incident(conn, incident_id, user) do
      emails = Emails.list_for_incident(incident)
      json(conn, %{data: Enum.map(emails, &email_json/1)})
    end
  end

  # POST /api/v1/incidents/:incident_id/emails
  def create(conn, %{"incident_id" => incident_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = params["email"] || %{}

    with {:ok, incident} <- fetch_authorized_incident(conn, incident_id, user) do
      case Emails.ingest_pasted(incident, user.id, attrs) do
        {:ok, %IncidentEmail{} = email} ->
          conn |> put_status(:created) |> json(%{data: email_json(email)})

        {:error, :empty_raw_text} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "raw_text is required"})

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    end
  end

  # POST /api/v1/incidents/:incident_id/emails/send
  def send_outbound(conn, %{"incident_id" => incident_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = params["email"] || %{}

    with {:ok, incident} <- fetch_authorized_incident(conn, incident_id, user),
         :ok <- authorize_privileged(conn, incident.building_id, user) do
      case Emails.send_outbound(incident, user.id, attrs) do
        {:ok, %IncidentEmail{} = email} ->
          conn |> put_status(:created) |> json(%{data: email_json(email)})

        {:error, :missing_to} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "to is required"})

        {:error, :missing_subject} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "subject is required"})

        {:error, :missing_body} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "body is required"})

        {:error, {:delivery_failed, reason}} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "Resend: #{inspect(reason)}"})

        {:error, %Ecto.Changeset{} = cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    end
  end

  # GET /api/v1/incidents/:incident_id/timeline
  def timeline(conn, %{"incident_id" => incident_id}) do
    user = Guardian.Plug.current_resource(conn)

    with {:ok, incident} <- fetch_authorized_incident(conn, incident_id, user) do
      json(conn, %{
        data: Emails.timeline(incident),
        inbox_alias: EmailAddressing.incident_alias(incident)
      })
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Charge l'incident et vérifie que `user` est membre du bâtiment ou
  # super_admin. Renvoie `{:ok, incident}` ou un response déjà rendu.
  defp fetch_authorized_incident(conn, incident_id, user) do
    case Incidents.get_incident(incident_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Incident introuvable"}) |> halt()
        {:halt, conn}

      incident ->
        cond do
          user.role == :super_admin ->
            {:ok, incident}

          Buildings.member?(incident.building_id, user.id) ->
            {:ok, incident}

          true ->
            conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
            {:halt, conn}
        end
    end
  end

  defp authorize_privileged(conn, building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role == :super_admin -> :ok
      user.role in @privileged_roles -> :ok
      member_role in @privileged_roles -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Réservé aux conseillers et au syndic"})
        |> halt()
    end
  end

  defp email_json(%IncidentEmail{} = e) do
    %{
      id: e.id,
      subject: e.subject,
      from_email: e.from_email,
      from_name: e.from_name,
      to_email: e.to_email,
      direction: to_string(e.direction),
      source: to_string(e.source),
      classification: e.classification && to_string(e.classification),
      ai_summary: e.ai_summary,
      delivery_status: e.delivery_status,
      correspondent_kind: e.correspondent_kind && to_string(e.correspondent_kind),
      status: to_string(e.status),
      body: e.text_body || strip_html(e.html_body),
      occurred_at: e.occurred_at && DateTime.to_iso8601(e.occurred_at),
      delivery_events: e.delivery_events || [],
      ai: ai_payload(e),
      pasted_by: pasted_by_json(e.pasted_by)
    }
  end

  defp ai_payload(%IncidentEmail{ai_data: data, classification_confidence: conf})
       when is_map(data) and map_size(data) > 0 do
    %{
      title: Map.get(data, "title"),
      priority: Map.get(data, "priority"),
      incident_category: Map.get(data, "incident_category"),
      suggested_action: Map.get(data, "suggested_action"),
      confidence: conf
    }
  end
  defp ai_payload(_), do: nil

  defp pasted_by_json(nil), do: nil
  defp pasted_by_json(%Ecto.Association.NotLoaded{}), do: nil
  defp pasted_by_json(%KomunBackend.Accounts.User{} = u),
    do: %{id: u.id, first_name: u.first_name, last_name: u.last_name}

  defp strip_html(nil), do: nil
  defp strip_html(""), do: nil
  defp strip_html(html), do: String.replace(html, ~r/<[^>]+>/, " ")

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
