defmodule KomunBackend.Notifications.Jobs.SendMagicLinkEmailJob do
  use Oban.Worker, queue: :emails, max_attempts: 3

  alias KomunBackend.Mailer
  import Swoosh.Email

  @default_base_url "https://komun.app"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "token" => token}}) do
    magic_url = "#{base_url()}/auth/verify?token=#{token}"

    new()
    |> to(email)
    |> from({"Komun", "noreply@komun.app"})
    |> subject("Votre lien de connexion Komun")
    |> html_body(build_html(email, magic_url))
    |> text_body("Connectez-vous à Komun: #{magic_url}\n\nCe lien expire dans 15 minutes.")
    |> Mailer.deliver()

    :ok
  end

  defp base_url do
    System.get_env("APP_BASE_URL", @default_base_url)
  end

  defp build_html(email, url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: Inter, sans-serif; max-width: 480px; margin: 0 auto; padding: 40px 20px;">
      <h1 style="color: #1E4FD8; font-size: 24px;">Connexion à Komun</h1>
      <p>Bonjour #{email},</p>
      <p>Cliquez sur le bouton ci-dessous pour vous connecter à votre espace Komun :</p>
      <a href="#{url}"
         style="display: inline-block; background: #1E4FD8; color: white; padding: 14px 28px;
                border-radius: 8px; text-decoration: none; font-weight: 600; margin: 20px 0;">
        Se connecter
      </a>
      <p style="color: #64748B; font-size: 13px;">
        Ou copiez ce lien dans votre navigateur :<br>
        <a href="#{url}" style="color: #1E4FD8; word-break: break-all;">#{url}</a>
      </p>
      <p style="color: #64748B; font-size: 14px;">Ce lien expire dans <strong>15 minutes</strong>.</p>
      <p style="color: #64748B; font-size: 12px;">Si vous n'avez pas demandé ce lien, ignorez cet email.</p>
    </body>
    </html>
    """
  end
end
