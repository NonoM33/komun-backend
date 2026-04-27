defmodule KomunBackend.InboundEmails do
  @moduledoc """
  Pipeline d'ingestion d'emails (entrants webhook + uploads admin).

  Centralise les helpers historiquement vissés dans
  `KomunBackendWeb.InboundEmailWebhookController` pour qu'ils soient
  réutilisables :

  * `system_author/0`        — l'utilisateur "système" qui porte les
    incidents auto-créés (super_admin existant).
  * `normalize_email/1`      — normalise un payload de webhook en map
    `%{from, from_name, to, cc, subject, body, received_at}`.
  * `format_email_body/1`    — formatte une map d'email en body markdown
    préfixé par `📧` (le format que le frontend sait rendre dans la
    timeline).
  * `route_email/2`          — passe l'email au router AI puis applique
    `:append` ou `:create` ; renvoie `{:ok, %{action, incident_id, ...}}`.

  Pas de logique de webhook ni d'auth ici : c'est un module métier
  pur, appelable depuis n'importe quel controller (webhook public,
  ingestion admin, etc.).
  """

  require Logger
  import Ecto.Query

  alias KomunBackend.{Incidents, Repo}
  alias KomunBackend.AI.IncidentRouter
  alias KomunBackend.Accounts.User

  @doc """
  Récupère un utilisateur super_admin pour porter les commentaires
  système. Renvoie `{:ok, user}` ou `{:error, :no_system_user}`.
  """
  def system_author do
    case Repo.one(from u in User, where: u.role == :super_admin, limit: 1) do
      nil -> {:error, :no_system_user}
      user -> {:ok, user}
    end
  end

  @doc """
  Normalise un payload de webhook (Resend, Cloudmailin, Gmail forwarder…)
  en map atomisée. Tolère les variantes de clés (`from` vs `from_email`,
  `text` vs `body`, …).
  """
  def normalize_email(params) when is_map(params) do
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

  @doc """
  Formate une map d'email en body markdown préfixé `📧 **sujet** …`.
  Le frontend repère ce préfixe pour rendre la card "email importé" dans
  la timeline d'un incident.
  """
  def format_email_body(email) when is_map(email) do
    cc =
      case email[:cc] || email["cc"] do
        list when is_list(list) and list != [] -> Enum.join(list, ", ")
        s when is_binary(s) and s != "" -> s
        _ -> nil
      end

    date_label =
      case email[:received_at] || email["received_at"] do
        %DateTime{} = dt -> Calendar.strftime(dt, "%d/%m/%Y %H:%M")
        s when is_binary(s) -> s
        _ -> ""
      end

    sender_name = email[:from_name] || email["from_name"] || email[:from] || email["from"] || "Inconnu"
    sender_email = email[:from] || email["from"] || ""
    subject = email[:subject] || email["subject"] || ""
    to = email[:to] || email["to"] || ""
    body = email[:body] || email["body"] || ""

    """
    📧 **#{subject}**
    De : **#{sender_name}** <#{sender_email}>
    À : #{to}
    """ <>
      if(cc, do: "Cc : #{cc}\n", else: "") <>
      "Date : #{date_label}\n\n" <>
      body
  end

  @doc """
  Route un email vers un incident (append) ou crée un nouvel incident.

  Renvoie `{:ok, result}` avec :

      %{action: :append, incident_id: id, comment_id: id}
      %{action: :create, incident_id: id}

  ou `{:error, reason}` si la création échoue.
  """
  def route_email(building_id, author_id, email) when is_binary(building_id) and is_binary(author_id) do
    open_incidents = Incidents.list_open_incidents(building_id)

    case IncidentRouter.route(email, open_incidents) do
      {:append, incident_id} ->
        case Incidents.add_comment(incident_id, author_id, %{
               "body" => format_email_body(email)
             }) do
          {:ok, comment} ->
            {:ok, %{action: :append, incident_id: incident_id, comment_id: comment.id}}

          {:error, reason} ->
            {:error, reason}
        end

      :create ->
        case create_incident_from_email(building_id, author_id, email) do
          {:ok, incident} -> {:ok, %{action: :create, incident_id: incident.id}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Crée un nouvel incident minimal à partir d'un email + le 1er commentaire.

  Le titre/description sont provisoires : `IncidentSummarizer.regenerate(:all)`
  les remplacera quand Groq aura tourné.
  """
  def create_incident_from_email(building_id, author_id, email) do
    title =
      (email[:subject] || email["subject"] || "")
      |> to_string()
      |> String.slice(0, 200)
      |> ensure_min_length("Email entrant — sujet à préciser")

    description =
      (email[:body] || email["body"] || "")
      |> to_string()
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

  # ── Private helpers ────────────────────────────────────────────────────

  defp get_in_either(map, keys) do
    Enum.find_value(keys, fn k -> map[k] end)
  end

  defp strip_html(nil), do: ""
  defp strip_html(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  defp ensure_min_length(s, fallback) do
    if String.length(s) >= 5, do: s, else: fallback
  end
end
