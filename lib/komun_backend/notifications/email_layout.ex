defmodule KomunBackend.Notifications.EmailLayout do
  @moduledoc """
  Layout HTML des emails Komun — porté depuis `web_v2/src/emails/layout.ts`.

  Tous les emails partagent le même cadre visuel : logo Komun en haut,
  carte blanche avec radius généreux, fond crème #FDF4EE, CTA coral.
  Format "tables + inline styles" pour rester compatible avec les
  clients email (Gmail, Outlook, Apple Mail…).

  La source de vérité du design reste le fichier TypeScript côté front
  (`web_v2/src/emails/layout.ts`) qui alimente la preview admin sur
  `/admin/emails`. Si on change l'un, on recopie dans l'autre.
  """

  @brand %{
    primary: "#EE6B5C",
    primary_dark: "#B24939",
    bg: "#FDF4EE",
    surface: "#FFFFFF",
    text: "#1A1A1A",
    text_muted: "#6B6860",
    line: "#EFE8DF",
    cta: "#EE6B5C",
    cta_text: "#FFFFFF"
  }

  @font_stack "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

  @doc """
  Enveloppe un body HTML dans le layout standard.

  Options :
  - `:preheader` — texte caché (aperçu dans la liste d'emails Gmail/Apple Mail)
  - `:footer` — bloc de pied de page custom (défaut = mention Komun + ignore)
  """
  def render(opts) do
    preheader = Keyword.get(opts, :preheader, "")
    body = Keyword.fetch!(opts, :body)

    footer =
      Keyword.get(
        opts,
        :footer,
        """
        <p style="margin:0 0 4px;color:#{@brand.text_muted};font-size:12px">Komun — la plateforme de votre résidence.</p>
        <p style="margin:0;color:#{@brand.text_muted};font-size:12px">Si vous n'êtes pas à l'origine de ce message, vous pouvez l'ignorer — aucune action ne sera effectuée.</p>
        """
      )

    pre =
      if preheader != "" do
        ~s(<div style="display:none;max-height:0;overflow:hidden;font-size:1px;line-height:1px;color:#{@brand.bg};opacity:0">#{escape(preheader)}</div>)
      else
        ""
      end

    """
    <!doctype html>
    <html lang="fr">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="color-scheme" content="light" />
        <meta name="supported-color-schemes" content="light" />
        <title>Komun</title>
      </head>
      <body style="margin:0;padding:0;background-color:#{@brand.bg};font-family:#{@font_stack};color:#{@brand.text}">
        #{pre}
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#{@brand.bg}">
          <tr>
            <td align="center" style="padding:32px 16px">
              <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%">
                <tr>
                  <td style="padding:0 0 24px">
                    <table role="presentation" cellpadding="0" cellspacing="0">
                      <tr>
                        <td style="padding-right:10px;vertical-align:middle">
                          <div style="width:40px;height:40px;border-radius:12px;background-color:#{@brand.primary};display:inline-block;text-align:center;line-height:40px;color:#fff;font-weight:700;font-size:18px;font-family:#{@font_stack}">K</div>
                        </td>
                        <td style="vertical-align:middle">
                          <span style="font-size:18px;font-weight:600;letter-spacing:-0.01em;color:#{@brand.text}">komun</span>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
                <tr>
                  <td style="background-color:#{@brand.surface};border:1px solid #{@brand.line};border-radius:24px;padding:32px 28px">
                    #{body}
                  </td>
                </tr>
                <tr>
                  <td style="padding:24px 8px 0">
                    #{footer}
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  @doc "Bouton CTA coral — raisonnablement supporté par tous les clients email."
  def cta_button(href, label) do
    """
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0">
      <tr>
        <td style="border-radius:14px;background-color:#{@brand.cta};box-shadow:0 8px 16px -8px rgba(238,107,92,0.4)">
          <a href="#{escape(href)}" style="display:inline-block;padding:14px 26px;color:#{@brand.cta_text};font-weight:600;font-size:15px;text-decoration:none;letter-spacing:-0.01em;font-family:#{@font_stack}">#{escape(label)}</a>
        </td>
      </tr>
    </table>
    """
  end

  def h1(text) do
    ~s(<h1 style="margin:0 0 12px;font-size:22px;font-weight:700;letter-spacing:-0.02em;color:#{@brand.text};font-family:#{@font_stack}">#{escape(text)}</h1>)
  end

  @doc "Paragraphe standard. `text` peut contenir du HTML pré-formaté (strong, a…)."
  def p(text) do
    ~s(<p style="margin:0 0 12px;font-size:15px;line-height:1.6;color:#{@brand.text}">#{text}</p>)
  end

  def muted(text) do
    ~s(<p style="margin:12px 0 0;font-size:12px;line-height:1.5;color:#{@brand.text_muted}">#{text}</p>)
  end

  def escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  def escape(s), do: escape(to_string(s))
end
