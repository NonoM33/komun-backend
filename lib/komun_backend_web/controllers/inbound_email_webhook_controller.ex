defmodule KomunBackendWeb.InboundEmailWebhookController do
  @moduledoc """
  Webhook entrant pour les emails redirigés vers Komun.

  Le copropriétaire/syndic peut configurer une adresse de transfert
  (Gmail, Outlook, Resend, Cloudmailin…) qui forwarde chaque mail vers
  cet endpoint. Le payload accepté est volontairement générique pour
  fonctionner avec plusieurs providers : on lit `from`, `to`, `subject`,
  `text`, `headers` (et optionnellement `building_id` quand le
  forwarder peut l'injecter).

  Pipeline :

    1. Auth — header `X-Komun-Webhook-Secret` doit matcher la variable
       d'env `INBOUND_EMAIL_WEBHOOK_SECRET`. Sans secret défini sur le
       déploiement, l'endpoint répond 404 (invisible).
    2. Résolution du bâtiment :
       - via le paramètre `building_id` quand fourni,
       - sinon via le local-part de `to` (pattern `incidents+<id>@…`).
    3. Construction d'un body au format compatible `📧` (le même que
       l'importeur Gmail) pour que le frontend le rende dans la timeline
       sans logique additionnelle.
    4. Routage AI : `IncidentRouter.route/2` décide append vs create.
    5. Append : on crée un `IncidentComment` rattaché au dossier
       choisi. Hooks de notif + summarizer en `:all` se déclenchent
       depuis `Incidents.add_comment/3`.
    6. Create : on crée un nouvel incident minimal (titre/description
       provisoires extraits du sujet/corps), on ajoute le 1er email
       comme commentaire, puis le summarizer en `:all` produit titre
       propre + description markdown + micro_summary.

  Toutes les opérations qui touchent à l'IA sont async — le webhook
  répond 200 dès que l'email est persisté, sans attendre Groq.
  """

  use KomunBackendWeb, :controller

  require Logger

  alias KomunBackend.{Incidents, Repo}
  alias KomunBackend.AI.IncidentRouter
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building

  defp system_author do
    import Ecto.Query

    case Repo.one(from u in User, where: u.role == :super_admin, limit: 1) do
      nil -> {:error, :no_system_user}
      user -> {:ok, user}
    end
  end

  defp fetch_building(id) when is_binary(id), do: Repo.get(Building, id)
  defp fetch_building(_), do: nil

  def create(conn, params) do
    expected = System.get_env("INBOUND_EMAIL_WEBHOOK_SECRET")

    cond do
      is_nil(expected) or expected == "" ->
        conn |> put_status(:not_found) |> json(%{error: "Not Found"})

      get_secret(conn) != expected ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})

      true ->
        process(conn, params)
    end
  end

  defp get_secret(conn) do
    case Plug.Conn.get_req_header(conn, "x-komun-webhook-secret") do
      [v | _] -> v
      _ -> nil
    end
  end

  defp process(conn, params) do
    with {:ok, building} <- resolve_building(params),
         {:ok, author} <- system_author(),
         email <- normalize_email(params) do
      open_incidents = Incidents.list_open_incidents(building.id)

      case IncidentRouter.route(email, open_incidents) do
        {:append, incident_id} ->
          Logger.info("[webhook] append email to incident=#{incident_id}")
          {:ok, comment} =
            Incidents.add_comment(incident_id, author.id, %{
              "body" => format_email_body(email)
            })

          conn
          |> put_status(:ok)
          |> json(%{action: "append", incident_id: incident_id, comment_id: comment.id})

        :create ->
          Logger.info("[webhook] create new incident from email")
          {:ok, incident} = create_incident_from_email(building.id, author.id, email)

          conn
          |> put_status(:created)
          |> json(%{action: "create", incident_id: incident.id})
      end
    else
      {:error, :building_not_resolved} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not resolve building from payload"})

      {:error, :no_system_user} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "No system user available"})

      {:error, reason} ->
        Logger.error("[webhook] failed: #{inspect(reason)}")
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp resolve_building(%{"building_id" => bid}) when is_binary(bid) do
    case Buildings.get_building(bid) do
      nil -> {:error, :building_not_resolved}
      b -> {:ok, b}
    end
  end

  defp resolve_building(%{"to" => to}) when is_binary(to) do
    # Format `incidents+<building_id>@<host>` : on extrait l'id après le
    # `+` du local-part. Permet de mutualiser une adresse unique.
    case Regex.run(~r/incidents\+([a-f0-9-]+)@/i, to) do
      [_, bid] ->
        case fetch_building(bid) do
          nil -> {:error, :building_not_resolved}
          b -> {:ok, b}
        end

      _ ->
        {:error, :building_not_resolved}
    end
  end

  defp resolve_building(_), do: {:error, :building_not_resolved}

  defp normalize_email(params) do
    %{
      from: get_in_either(params, ["from", "from_email"]),
      from_name: get_in_either(params, ["from_name"]),
      to: params["to"],
      cc: params["cc"] || [],
      subject: params["subject"] || "(sans sujet)",
      body: params["text"] || params["body"] || strip_html(params["html"]),
      received_at: params["received_at"] || DateTime.utc_now()
    }
  end

  defp get_in_either(map, keys) do
    Enum.find_value(keys, fn k -> map[k] end)
  end

  defp strip_html(nil), do: ""
  defp strip_html(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  defp format_email_body(email) do
    cc =
      case email.cc do
        list when is_list(list) and list != [] -> Enum.join(list, ", ")
        s when is_binary(s) and s != "" -> s
        _ -> nil
      end

    date_label =
      case email.received_at do
        %DateTime{} = dt -> Calendar.strftime(dt, "%d/%m/%Y %H:%M")
        s when is_binary(s) -> s
        _ -> ""
      end

    sender_name = email.from_name || (email.from || "Inconnu")

    """
    📧 **#{email.subject}**
    De : **#{sender_name}** <#{email.from}>
    À : #{email.to || ""}
    """ <>
      if(cc, do: "Cc : #{cc}\n", else: "") <>
      "Date : #{date_label}\n\n" <>
      (email.body || "")
  end

  defp create_incident_from_email(building_id, author_id, email) do
    # Titre / description provisoires : le summarizer va les remplacer
    # une fois Groq passé. On garde le sujet de l'email et un extrait
    # du body au cas où Groq tombe.
    title =
      email.subject
      |> String.slice(0, 200)
      |> ensure_min_length("Email entrant — sujet à préciser")

    description =
      (email.body || "")
      |> String.slice(0, 1500)
      |> case do
        "" -> "(corps vide)"
        s -> s
      end

    attrs = %{
      "title" => title,
      "description" => description,
      "category" => "autre",
      "severity" => "medium"
    }

    with {:ok, incident} <- Incidents.create_incident(building_id, author_id, attrs),
         {:ok, _comment} <-
           Incidents.add_comment(incident.id, author_id, %{
             "body" => format_email_body(email)
           }) do
      {:ok, incident}
    end
  end

  defp ensure_min_length(s, fallback) do
    if String.length(s) >= 5, do: s, else: fallback
  end
end
