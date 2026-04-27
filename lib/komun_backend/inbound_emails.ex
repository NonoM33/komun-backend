defmodule KomunBackend.InboundEmails do
  @moduledoc """
  Pipeline d'ingestion d'emails — helpers réutilisables depuis le
  webhook public et l'ingestion admin.
  """

  require Logger

  alias KomunBackend.{Incidents, Repo}
  alias KomunBackend.AI.IncidentRouter
  alias KomunBackend.Accounts.User

  @doc "Récupère un super_admin pour porter les commentaires système."
  def system_author do
    import Ecto.Query

    case Repo.one(from(u in User, where: u.role == :super_admin, limit: 1)) do
      nil -> {:error, :no_system_user}
      user -> {:ok, user}
    end
  end

  @doc "Formate un email en body markdown préfixé `📧 **sujet** …`."
  def format_email_body(email) do
    subject = stringy(email, :subject)
    sender_email = stringy(email, :from)
    sender_name = stringy(email, :from_name) |> default_to(sender_email)
    to = stringy(email, :to)
    body = stringy(email, :body)
    date_label = stringy(email, :received_at)

    cc_line =
      case email[:cc] || email["cc"] do
        nil -> ""
        "" -> ""
        list when is_list(list) -> "Cc : " <> Enum.join(list, ", ") <> "\n"
        s when is_binary(s) -> "Cc : " <> s <> "\n"
        _ -> ""
      end

    "📧 **" <> subject <> "**\n" <>
      "De : **" <> sender_name <> "** <" <> sender_email <> ">\n" <>
      "À : " <> to <> "\n" <>
      cc_line <>
      "Date : " <> date_label <> "\n\n" <>
      body
  end

  @doc """
  Route un email vers append (incident existant) ou create (nouveau).
  Renvoie `{:ok, %{action: :append|:create, incident_id, comment_id?}}`
  ou `{:error, reason}`.
  """
  def route_email(building_id, author_id, email)
      when is_binary(building_id) and is_binary(author_id) do
    open_incidents = Incidents.list_open_incidents(building_id)

    case IncidentRouter.route(email, open_incidents) do
      {:append, incident_id} ->
        case Incidents.add_comment(incident_id, author_id, %{"body" => format_email_body(email)}) do
          {:ok, comment} -> {:ok, %{action: :append, incident_id: incident_id, comment_id: comment.id}}
          {:error, reason} -> {:error, reason}
        end

      :create ->
        case create_incident_from_email(building_id, author_id, email) do
          {:ok, incident} -> {:ok, %{action: :create, incident_id: incident.id}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Crée un incident minimal + 1er commentaire à partir d'un email.
  Le summarizer (`IncidentSummarizer.regenerate(:all)`) regenère
  titre + description + micro_summary après coup.
  """
  def create_incident_from_email(building_id, author_id, email) do
    title =
      email
      |> stringy(:subject)
      |> String.slice(0, 200)
      |> ensure_min_length("Email entrant — sujet à préciser")

    description =
      email
      |> stringy(:body)
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
           Incidents.add_comment(incident.id, author_id, %{"body" => format_email_body(email)}) do
      {:ok, incident}
    end
  end

  # ── Helpers privés ────────────────────────────────────────────────────

  defp stringy(email, key) when is_atom(key) do
    str_key = Atom.to_string(key)
    value = email[key] || email[str_key]
    to_string_safe(value)
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(s) when is_binary(s), do: s
  defp to_string_safe(%DateTime{} = dt), do: Calendar.strftime(dt, "%d/%m/%Y %H:%M")
  defp to_string_safe(other), do: to_string(other)

  defp default_to("", fallback), do: fallback
  defp default_to(value, _fallback), do: value

  defp ensure_min_length(s, fallback) do
    if String.length(s) >= 5, do: s, else: fallback
  end
end
