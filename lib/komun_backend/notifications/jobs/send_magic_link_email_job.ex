defmodule KomunBackend.Notifications.Jobs.SendMagicLinkEmailJob do
  use Oban.Worker, queue: :emails, max_attempts: 3

  alias KomunBackend.Mailer
  alias KomunBackend.Notifications.EmailLayout
  import Swoosh.Email

  @default_base_url "https://komun.app"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"email" => email, "token" => token} = args}) do
    magic_url = "#{base_url()}/auth/verify?token=#{token}"
    code = Map.get(args, "code")

    new()
    |> to(email)
    |> from({"Komun", "noreply@komun.app"})
    |> subject("Votre lien de connexion à Komun")
    |> html_body(build_html(email, magic_url, code))
    |> text_body(build_text(email, magic_url, code))
    |> Mailer.deliver()

    :ok
  end

  defp base_url do
    System.get_env("APP_BASE_URL", @default_base_url)
  end

  # Source de vérité du design : `web_v2/src/emails/registry.ts` (template
  # `magicLinkTemplate`). Si on change l'un, on recopie dans l'autre pour
  # que la preview admin corresponde à ce qu'on envoie vraiment.
  defp build_html(email, url, code) do
    EmailLayout.render(
      preheader: "Un clic ou un code pour accéder à Komun — valable 15 min.",
      body:
        EmailLayout.h1("Se connecter à Komun") <>
          EmailLayout.p(
            "Bonjour, vous avez demandé à vous connecter avec <strong>#{EmailLayout.escape(email)}</strong>. Deux options selon votre situation :"
          ) <>
          EmailLayout.cta_button(url, "Ouvrir Komun") <>
          code_block(code) <>
          EmailLayout.muted(
            ~s(Lien et code valables 15 minutes, à usage unique. Si le bouton ne fonctionne pas, copiez-collez :<br /><a href="#{EmailLayout.escape(url)}" style="color:#B24939;word-break:break-all">#{EmailLayout.escape(url)}</a>)
          )
    )
  end

  # Bloc dédié au code 6 chiffres, mis en avant pour les utilisateurs qui
  # ouvrent l'email depuis Mail iOS : un clic sur le lien ouvre Safari
  # (et pas la PWA standalone), donc la session se pose dans le mauvais
  # contexte. Le code à recopier dans l'app contourne ce piège iOS.
  defp code_block(nil), do: ""

  defp code_block(code) when is_binary(code) do
    """
    <div style="margin:24px 0;padding:20px;border:1px solid #F2D7D1;border-radius:14px;background:#FFF5F2;text-align:center">
      <p style="margin:0 0 8px;color:#666;font-size:13px;font-family:Inter,system-ui,sans-serif">
        Ou ouvrez Komun sur votre téléphone et tapez ce code :
      </p>
      <div style="font-family:'SFMono-Regular',Consolas,'Liberation Mono',monospace;font-size:32px;letter-spacing:0.4em;color:#B24939;font-weight:700">
        #{EmailLayout.escape(format_code_display(code))}
      </div>
    </div>
    """
  end

  defp build_text(email, url, code) do
    code_text =
      case code do
        nil -> ""
        c -> "\nOu tapez ce code dans l'application :\n#{format_code_display(c)}\n"
      end

    """
    Se connecter à Komun

    Bonjour, vous avez demandé à vous connecter avec #{email}. Deux options :

    1) Cliquez sur ce lien (ouvrira votre navigateur par défaut) :
    #{url}
    #{code_text}
    Lien et code valables 15 minutes, usage unique.
    Si vous n'êtes pas à l'origine de ce message, vous pouvez l'ignorer.
    """
  end

  # 123456 → "123 456" pour faciliter la lecture / dictée vocale.
  defp format_code_display(code) when is_binary(code) do
    case String.length(code) do
      6 -> String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)
      _ -> code
    end
  end
end
