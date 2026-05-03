defmodule KomunBackendWeb.EventShareController do
  @moduledoc """
  Endpoint de prévisualisation publique pour les liens partagés
  (iMessage, WhatsApp, Slack, Teams, etc.).

  L'URL canonique partagée est `https://api.komun.app/share/events/:id`.
  Le contenu retourné est du HTML minimaliste avec :
    - les `<meta property="og:*">` (Open Graph) pour les bots
    - les `<meta name="twitter:*">` pour Twitter / X
    - une redirection JS + meta-refresh vers le SPA pour les humains
      (`https://komun.app/events/:id`)

  Pas d'authentification : un lien partagé est public par construction.
  Si l'événement est en draft / annulé / introuvable, on renvoie une
  prévisualisation générique « Komun » sans données sensibles plutôt
  qu'un 404 — ça évite que le lien soit pollué de "preview unavailable".
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Events
  alias KomunBackend.Events.Event

  @default_image "https://komun.app/og-default.png"

  def show(conn, %{"id" => event_id}) do
    {title, description, image, redirect_url} = build_payload(event_id)

    html = render_html(title, description, image, redirect_url)

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, html)
  end

  defp build_payload(event_id) do
    case Events.get_event(event_id) do
      %Event{status: :draft} ->
        generic()

      %Event{status: :cancelled} = event ->
        {
          "Annulé : #{event.title}",
          event.cancelled_reason || "Cet événement a été annulé.",
          @default_image,
          spa_url(event.id)
        }

      %Event{} = event ->
        {
          event.title,
          format_description(event),
          cover_or_default(event.cover_image_url),
          spa_url(event.id)
        }

      nil ->
        generic()
    end
  end

  defp generic do
    {
      "Komun — Le lien social de votre résidence",
      "Discutez, votez, organisez et entretenez votre copropriété en bonne intelligence.",
      @default_image,
      "https://komun.app/"
    }
  end

  defp format_description(%Event{} = event) do
    base = event.description || "Un événement de voisinage organisé sur Komun."

    when_str =
      Calendar.strftime(event.starts_at, "📅 %d/%m/%Y à %H:%M")

    where =
      case event.location_label do
        nil -> ""
        "" -> ""
        loc -> " · 📍 #{loc}"
      end

    "#{when_str}#{where}\n\n#{base}"
    |> String.slice(0, 280)
  end

  # Si la cover_image_url est relative (ex. /uploads/events/...), on la
  # préfixe avec l'origin du backend pour que les bots OG puissent la
  # fetcher en absolu.
  defp cover_or_default(nil), do: @default_image
  defp cover_or_default(""), do: @default_image
  defp cover_or_default("http" <> _ = url), do: url

  defp cover_or_default("/" <> rest) do
    "#{backend_origin()}/#{rest}"
  end

  defp cover_or_default(other), do: "#{backend_origin()}/#{other}"

  defp backend_origin do
    System.get_env("BACKEND_PUBLIC_URL", "https://api.komun.app")
  end

  defp spa_url(event_id) do
    base = System.get_env("APP_BASE_URL", "https://komun.app")
    "#{base}/events/#{event_id}"
  end

  # Échappe juste ce qui peut sortir du contexte attribut. Les valeurs
  # utilisateur viennent de la base — pas de XSS possible côté
  # iMessage / WhatsApp (les bots ne rendent pas le JS), mais on reste
  # prudent côté browser fallback.
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
