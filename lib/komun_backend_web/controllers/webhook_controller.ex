defmodule KomunBackendWeb.WebhookController do
  @moduledoc """
  Endpoints de webhooks externes (Resend principalement).

  ## POST /api/v1/webhooks/resend/inbound

  Reçoit les emails entrants envoyés à `<alias>@inbound.komun.app`
  (Resend Inbound Email feature → POST JSON sur cette URL).

  Auth : header `Authorization: Bearer <RESEND_INBOUND_SECRET>`. Le
  secret est stocké en variable d'env. Pas de signature HMAC pour
  l'instant — assez sécure tant que le secret est rotaté en cas de
  fuite et que l'endpoint passe par HTTPS.

  Logique :

  1. Vérifier le secret. 401 si KO.
  2. Extraire `to` (premier destinataire) → résoudre le bâtiment
     via `inbound_alias`. 404 si pas de match.
  3. Chercher un brouillon ou un incident `:open` du bâtiment qui
     match le sujet (mots-clés communs sur le titre). Si trouvé,
     **ajouter un commentaire** au format `📧` (timeline frontend).
  4. Sinon, **créer un nouveau brouillon** d'incident avec :
     - title = subject (truncated à 200)
     - description = courte synthèse `Email reçu le ... de ... — sujet : ...`
     - status = brouillon, severity = medium, category = autre
     - Reporter = un user système (super_admin par défaut, voir notes)
     - Premier commentaire 📧 avec le contenu complet de l'email

  ## Format Resend attendu (cf. https://resend.com/docs/inbound)

  ```json
  {
    "from": {"email": "voisin@gmail.com", "name": "Pascale"},
    "to": [{"email": "unisson@inbound.komun.app", "name": ""}],
    "subject": "Panne ascenseur",
    "text": "Bonjour, l'ascenseur ne marche plus...",
    "html": "<p>Bonjour...</p>",
    "date": "2026-04-28T10:00:00Z",
    "attachments": [
      {"filename": "photo.jpg", "content_type": "image/jpeg", "content": "<base64>"}
    ]
  }
  ```

  Les attachments base64 sont décodés et uploadés via `Incidents.attach_file/3`
  (mêmes contraintes que l'upload manuel : PDF/JPEG/PNG/HEIC/WebP, 15 Mo max).
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.{Incidents, Repo}
  alias KomunBackend.Buildings.Building
  import Ecto.Query

  require Logger

  def resend_inbound(conn, params) do
    with :ok <- authorize(conn),
         {:ok, building} <- resolve_building(params),
         {:ok, system_user} <- get_system_user() do
      handle_inbound(conn, params, building, system_user)
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      {:error, :no_building} ->
        Logger.warning("[resend-inbound] no building matches `to` field")
        conn |> put_status(:not_found) |> json(%{error: "no_building_match"})

      {:error, :no_system_user} ->
        Logger.error("[resend-inbound] no super_admin user available as reporter")
        conn |> put_status(:internal_server_error) |> json(%{error: "no_system_user"})

      other ->
        Logger.error("[resend-inbound] unexpected error: #{inspect(other)}")
        conn |> put_status(:internal_server_error) |> json(%{error: "unexpected"})
    end
  end

  # ── Auth ────────────────────────────────────────────────────────────────

  defp authorize(conn) do
    expected = secret()

    cond do
      is_nil(expected) or expected == "" ->
        # Si pas de secret configuré, on refuse plutôt que d'accepter
        # tout le monde — fail-safe.
        Logger.error("[resend-inbound] RESEND_INBOUND_SECRET not configured")
        {:error, :unauthorized}

      true ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] when token == expected -> :ok
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp secret, do: System.get_env("RESEND_INBOUND_SECRET")

  # ── Building lookup ─────────────────────────────────────────────────────

  defp resolve_building(params) do
    to = extract_to_address(params)

    cond do
      is_nil(to) ->
        {:error, :no_building}

      true ->
        alias_part =
          to
          |> String.split("@", parts: 2)
          |> List.first()
          |> to_string()
          |> String.downcase()
          |> String.trim()

        case Repo.one(from b in Building, where: b.inbound_alias == ^alias_part and b.is_active == true) do
          nil -> {:error, :no_building}
          building -> {:ok, building}
        end
    end
  end

  # Resend envoie `to` comme une liste d'objets `{email, name}` ou
  # parfois une chaîne simple. On gère les deux.
  defp extract_to_address(%{"to" => [%{"email" => email} | _]}) when is_binary(email), do: email
  defp extract_to_address(%{"to" => [email | _]}) when is_binary(email), do: email
  defp extract_to_address(%{"to" => email}) when is_binary(email), do: email
  defp extract_to_address(_), do: nil

  # ── System user ─────────────────────────────────────────────────────────

  # Le brouillon créé par webhook a besoin d'un reporter. On prend le
  # premier super_admin actif. Plus propre à terme : un compte
  # `system@komun.app` dédié, identifiable côté UI.
  defp get_system_user do
    case Repo.one(
           from u in KomunBackend.Accounts.User,
             where: u.role == :super_admin,
             order_by: [asc: u.inserted_at],
             limit: 1
         ) do
      nil -> {:error, :no_system_user}
      user -> {:ok, user}
    end
  end

  # ── Inbound handling ────────────────────────────────────────────────────

  defp handle_inbound(conn, params, building, system_user) do
    subject = String.slice(get_field(params, "subject", "Email entrant"), 0, 200)
    body_text = pick_body(params)
    from_name = get_in(params, ["from", "name"]) || ""
    from_email = get_in(params, ["from", "email"]) || ""
    date_str = get_field(params, "date", "")

    # 1. Cherche un dossier existant qui match (matching naïf : sujet
    # identique normalisé, ouvert ou brouillon, créé dans les 30j).
    case find_matching_incident(building.id, subject) do
      nil ->
        create_incident_with_email(
          building, system_user, subject, body_text, from_name, from_email, date_str, params
        )
        |> respond(conn, :created)

      %Incidents.Incident{} = existing ->
        append_comment_to_incident(
          existing, system_user, subject, body_text, from_name, from_email, date_str, params
        )
        |> respond(conn, :ok)
    end
  end

  defp find_matching_incident(building_id, subject) do
    normalized = subject |> String.downcase() |> String.trim()
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :day)

    Repo.one(
      from i in Incidents.Incident,
        where:
          i.building_id == ^building_id and
            i.status in [:brouillon, :open, :in_progress] and
            i.inserted_at > ^cutoff and
            fragment("LOWER(?) = ?", i.title, ^normalized),
        limit: 1
    )
  end

  defp create_incident_with_email(building, reporter, subject, body, from_name, from_email, date, params) do
    description =
      "Email entrant ingéré automatiquement le " <>
        date_or_now(date) <>
        " — expéditeur : #{from_name} <#{from_email}>. Sujet : #{subject}."

    attrs = %{
      "title" => subject,
      "description" => description,
      "category" => "autre",
      "severity" => "medium",
      "status" => "brouillon"
    }

    case Incidents.create_incident(building.id, reporter.id, attrs) do
      {:ok, incident} ->
        post_email_comment(incident, reporter, subject, body, from_name, from_email, date)
        upload_inbound_attachments(incident, reporter, params)
        {:ok, %{action: "created", incident_id: incident.id}}

      {:error, cs} ->
        Logger.error("[resend-inbound] create_incident failed: #{inspect(cs)}")
        {:error, :create_failed}
    end
  end

  defp append_comment_to_incident(incident, reporter, subject, body, from_name, from_email, date, params) do
    post_email_comment(incident, reporter, subject, body, from_name, from_email, date)
    upload_inbound_attachments(incident, reporter, params)
    {:ok, %{action: "appended", incident_id: incident.id}}
  end

  defp post_email_comment(incident, author, subject, body, from_name, from_email, date) do
    formatted_date = format_date_fr(date)

    body_md =
      "📧 **#{subject}**\n" <>
        "De : **#{from_name}** <#{from_email}>\n" <>
        "Date : #{formatted_date}\n\n" <>
        truncate(body, 5000)

    Incidents.add_comment(incident.id, author.id, %{"body" => body_md})
  end

  defp upload_inbound_attachments(incident, uploader, %{"attachments" => atts}) when is_list(atts) do
    Enum.each(atts, fn
      %{"filename" => name, "content_type" => mime, "content" => b64} when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, bytes} ->
            tmp = Path.join(System.tmp_dir!(), "inbound-#{:erlang.unique_integer([:positive])}-#{name}")
            File.write!(tmp, bytes)

            attrs = %{
              "kind" => infer_kind(mime),
              "filename" => name,
              "file_url" => "/uploads/incidents/#{incident.id}/#{name}",
              "file_size_bytes" => byte_size(bytes),
              "mime_type" => mime
            }

            # Note : pour aller plus loin il faudrait sauvegarder le
            # fichier dans /priv/static/uploads/... (cf. IncidentController.do_upload)
            # — ici on enregistre juste la métadonnée. À itérer.
            _ = Incidents.attach_file(incident.id, uploader, attrs)
            File.rm(tmp)

          :error ->
            Logger.warning("[resend-inbound] base64 decode failed for #{name}")
        end

      _ ->
        :ok
    end)
  end

  defp upload_inbound_attachments(_, _, _), do: :ok

  defp infer_kind(mime) when is_binary(mime) do
    if String.starts_with?(mime, "image/"), do: :photo, else: :document
  end

  defp infer_kind(_), do: :document

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp pick_body(params) do
    cond do
      is_binary(params["text"]) and params["text"] != "" -> params["text"]
      is_binary(params["html"]) and params["html"] != "" -> strip_html(params["html"])
      true -> "[email vide]"
    end
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&#39;/, "'")
    |> String.trim()
  end

  defp truncate(text, n) when byte_size(text) > n,
    do: binary_part(text, 0, n) <> "\n\n[…email tronqué pour respecter la limite]"

  defp truncate(text, _), do: text

  defp format_date_fr(""), do: now_fr()

  defp format_date_fr(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%d/%m/%Y %H:%M")
      _ -> iso
    end
  end

  defp format_date_fr(_), do: now_fr()

  defp now_fr, do: Calendar.strftime(DateTime.utc_now(), "%d/%m/%Y %H:%M")

  defp date_or_now(""), do: now_fr()

  defp date_or_now(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%d/%m/%Y à %H:%M")
      _ -> now_fr()
    end
  end

  defp date_or_now(_), do: now_fr()

  defp get_field(map, key, default) do
    case map do
      %{} -> Map.get(map, key) || default
      _ -> default
    end
  end

  defp respond({:ok, payload}, conn, status) do
    conn |> put_status(status) |> json(%{data: payload})
  end

  defp respond({:error, reason}, conn, _status) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
  end
end
