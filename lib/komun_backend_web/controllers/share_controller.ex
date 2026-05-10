defmodule KomunBackendWeb.ShareController do
  @moduledoc """
  Endpoint public unifié pour les previews Open Graph (iMessage,
  WhatsApp, Slack, Discord, Telegram, LinkedIn…). Une seule URL canonique
  par type de ressource :

      GET /share/events/:id     → titre + description + photo de l'event
      GET /share/incidents/:id  → titre + description + 1ère photo
      GET /share/doleances/:id  → titre + description + 1ère photo

  Pas d'authentification : un lien partagé est public par construction.
  Si la ressource est confidentielle (incident `:council_only`,
  dossier en draft, doléance archivée), on retombe sur une preview Komun
  générique sans données sensibles plutôt qu'un 404 — ça évite que le
  lien soit pollué de "preview unavailable".
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Doleances
  alias KomunBackend.Doleances.Doleance
  alias KomunBackend.Events
  alias KomunBackend.Events.Event
  alias KomunBackend.Incidents
  alias KomunBackend.Incidents.Incident

  @default_image "https://komun.app/og-default.png"

  def show(conn, %{"resource" => resource, "id" => id}) do
    {title, description, image, redirect_url} = build_payload(resource, id)
    html = render_html(title, description, image, redirect_url)

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, html)
  end

  # ── Builders par type de ressource ───────────────────────────────────────

  defp build_payload("events", id), do: build_event_payload(id)
  defp build_payload("incidents", id), do: build_incident_payload(id)
  defp build_payload("doleances", id), do: build_doleance_payload(id)
  defp build_payload(_, _), do: generic()

  defp build_event_payload(event_id) do
    case Events.get_event(event_id) do
      %Event{status: :draft} ->
        generic()

      %Event{status: :cancelled} = event ->
        {
          "Annulé : #{event.title}",
          event.cancelled_reason || "Cet événement a été annulé.",
          @default_image,
          spa_url("events", event.id)
        }

      %Event{} = event ->
        {
          event.title,
          format_event_description(event),
          cover_or_default(event.cover_image_url),
          spa_url("events", event.id)
        }

      nil ->
        generic()
    end
  end

  defp build_incident_payload(incident_id) do
    case Incidents.get_incident(incident_id) do
      nil ->
        generic()

      # Confidentiel CS : on ne donne ni titre, ni description, ni photo.
      # La preview est générique (« un incident sur Komun ») pour ne pas
      # révéler le nom / contenu côté iMessage.
      %Incident{visibility: :council_only} ->
        {
          "Incident confidentiel — Komun",
          "Un signalement réservé au conseil syndical et au syndic.",
          @default_image,
          spa_url("incidents", incident_id)
        }

      %Incident{status: :brouillon} ->
        # Brouillon = pas encore validé par un humain → ne pas exposer
        # côté preview publique.
        generic()

      %Incident{} = inc ->
        first_photo = (inc.photo_urls || []) |> List.first()

        {
          inc.title,
          format_incident_description(inc),
          cover_or_default(first_photo),
          spa_url("incidents", inc.id)
        }
    end
  end

  defp build_doleance_payload(doleance_id) do
    case safe_get_doleance(doleance_id) do
      nil ->
        generic()

      %Doleance{status: :brouillon} ->
        generic()

      %Doleance{} = d ->
        first_photo = (d.photo_urls || []) |> List.first()

        {
          d.title,
          format_doleance_description(d),
          cover_or_default(first_photo),
          spa_url("doleances", d.id)
        }
    end
  end

  # Doleances n'a pas (encore) de get_doleance/1 sans bang public —
  # on encapsule pour ne pas crasher sur un id inexistant.
  defp safe_get_doleance(id) do
    Doleances.get_doleance(id)
  rescue
    _ -> nil
  end

  # ── Formatteurs description (≤ 280 chars pour rentrer dans og:description) ──

  defp format_event_description(%Event{} = event) do
    base = event.description || "Un événement de voisinage organisé sur Komun."

    when_str = Calendar.strftime(event.starts_at, "📅 %d/%m/%Y à %H:%M")

    where =
      case event.location_label do
        nil -> ""
        "" -> ""
        loc -> " · 📍 #{loc}"
      end

    "#{when_str}#{where}\n\n#{base}" |> String.slice(0, 280)
  end

  defp format_incident_description(%Incident{} = inc) do
    cat = if inc.category, do: "[#{inc.category}] ", else: ""
    severity_label = severity_label(inc.severity)
    base = inc.description || "Signalement déposé par un voisin sur Komun."

    "#{cat}#{severity_label}\n\n#{base}" |> String.slice(0, 280)
  end

  defp format_doleance_description(%Doleance{} = d) do
    base = d.description || "Une réclamation collective déposée sur Komun."
    "#{base}" |> String.slice(0, 280)
  end

  defp severity_label(:critical), do: "🔴 Critique"
  defp severity_label(:high), do: "🟠 Élevé"
  defp severity_label(:medium), do: "🟡 Moyen"
  defp severity_label(:low), do: "🟢 Faible"
  defp severity_label(_), do: ""

  # ── Helpers communs ──────────────────────────────────────────────────────

  defp generic do
    {
      "Komun — Le lien social de votre résidence",
      "Discutez, votez, organisez et entretenez votre copropriété en bonne intelligence.",
      @default_image,
      "https://komun.app/"
    }
  end

  defp cover_or_default(nil), do: @default_image
  defp cover_or_default(""), do: @default_image
  defp cover_or_default("http" <> _ = url), do: url
  defp cover_or_default("/" <> rest), do: "#{backend_origin()}/#{rest}"
  defp cover_or_default(other), do: "#{backend_origin()}/#{other}"

  defp backend_origin do
    System.get_env("BACKEND_PUBLIC_URL", "https://api.komun.app")
  end

  defp spa_url(resource, id) do
    base = System.get_env("APP_BASE_URL", "https://komun.app")
    "#{base}/#{resource}/#{id}"
  end

  defp h(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp h(_), do: ""

  defp render_html(title, description, image, redirect_url) do
    """
    <!DOCTYPE html>
    <html lang="fr">
    <head>
      <meta charset="UTF-8" />
      <title>#{h(title)} — Komun</title>
      <meta name="viewport" content="width=device-width, initial-scale=1" />

      <!-- Open Graph (Facebook, iMessage, WhatsApp, LinkedIn, Slack) -->
      <meta property="og:type" content="article" />
      <meta property="og:title" content="#{h(title)}" />
      <meta property="og:description" content="#{h(description)}" />
      <meta property="og:image" content="#{h(image)}" />
      <meta property="og:url" content="#{h(redirect_url)}" />
      <meta property="og:site_name" content="Komun" />
      <meta property="og:locale" content="fr_FR" />

      <!-- Twitter / X -->
      <meta name="twitter:card" content="summary_large_image" />
      <meta name="twitter:title" content="#{h(title)}" />
      <meta name="twitter:description" content="#{h(description)}" />
      <meta name="twitter:image" content="#{h(image)}" />

      <!-- Redirection humaine vers le SPA. Les bots ignorent. -->
      <meta http-equiv="refresh" content="0;url=#{h(redirect_url)}" />
      <link rel="canonical" href="#{h(redirect_url)}" />

      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Inter", sans-serif; max-width: 640px; margin: 4rem auto; padding: 1rem; color: #0f172a; }
        h1 { font-size: 1.5rem; }
        a { color: #B24939; }
        img { max-width: 100%; border-radius: 12px; margin: 1.5rem 0; }
      </style>
    </head>
    <body>
      <p>Redirection vers Komun…</p>
      <h1>#{h(title)}</h1>
      <img src="#{h(image)}" alt="" />
      <p>#{h(description)}</p>
      <p><a href="#{h(redirect_url)}">Continuer vers Komun →</a></p>
      <script>window.location.replace(#{Jason.encode!(redirect_url)});</script>
    </body>
    </html>
    """
  end
end
