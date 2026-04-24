defmodule KomunBackend.Notifications.Jobs.SendMagicLinkEmailJob do
  use Oban.Worker, queue: :emails, max_attempts: 3

  alias KomunBackend.Mailer
  alias KomunBackend.Notifications.EmailLayout
  import Swoosh.Email

  @default_base_url "https://komun.app"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "token" => token}}) do
    magic_url = "#{base_url()}/auth/verify?token=#{token}"

    new()
    |> to(email)
    |> from({"Komun", "noreply@komun.app"})
    |> subject("Votre lien de connexion à Komun")
    |> html_body(build_html(email, magic_url))
    |> text_body(
      """
      Se connecter à Komun

      Bonjour, vous avez demandé à vous connecter avec #{email}. Ouvrez ce lien
      pour accéder à votre espace :

      #{magic_url}

      Ce lien est valable 15 minutes et ne peut être utilisé qu'une fois.
      Si vous n'êtes pas à l'origine de ce message, vous pouvez l'ignorer.
      """
    )
    |> Mailer.deliver()

    :ok
  end

  defp base_url do
    System.get_env("APP_BASE_URL", @default_base_url)
  end

  # Source de vérité du design : `web_v2/src/emails/registry.ts` (template
  # `magicLinkTemplate`). Si on change l'un, on recopie dans l'autre pour
  # que la preview admin corresponde à ce qu'on envoie vraiment.
  defp build_html(email, url) do
    EmailLayout.render(
      preheader: "Un clic pour accéder à votre espace Komun — valable 15 min.",
      body:
        EmailLayout.h1("Se connecter à Komun") <>
          EmailLayout.p(
            "Bonjour, vous avez demandé à vous connecter avec <strong>#{EmailLayout.escape(email)}</strong>. Cliquez sur le bouton ci-dessous pour ouvrir votre espace."
          ) <>
          EmailLayout.cta_button(url, "Ouvrir Komun") <>
          EmailLayout.muted(
            ~s(Ce lien est valable 15 minutes et ne peut être utilisé qu'une fois. Si le bouton ne fonctionne pas, copiez-collez cette adresse dans votre navigateur :<br /><a href="#{EmailLayout.escape(url)}" style="color:#B24939;word-break:break-all">#{EmailLayout.escape(url)}</a>)
          )
    )
  end
end
