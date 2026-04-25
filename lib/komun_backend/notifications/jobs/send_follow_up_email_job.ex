defmodule KomunBackend.Notifications.Jobs.SendFollowUpEmailJob do
  @moduledoc """
  Envoie un email aux comptes syndic du bâtiment quand le conseil
  syndical (ou le syndic lui-même) relance un dossier d'incident.

  Le debounce 24h est appliqué côté `Incidents.maybe_enqueue_follow_up_email/3` :
  si on est ici, c'est qu'on a déjà passé le filtre. Le job se contente
  d'envoyer.
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  import Swoosh.Email
  require Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Mailer
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Incidents.Incident
  alias KomunBackend.Notifications.EmailLayout

  @default_base_url "https://komun.app"

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"incident_id" => incident_id, "follower_id" => follower_id, "message" => message}
      }) do
    incident = Repo.get(Incident, incident_id)
    follower = Repo.get(User, follower_id)

    cond do
      is_nil(incident) -> {:discard, :incident_missing}
      is_nil(follower) -> {:discard, :follower_missing}
      true -> deliver_to_syndic(incident, follower, message)
    end
  end

  defp deliver_to_syndic(%Incident{} = incident, %User{} = follower, message) do
    recipients = syndic_recipients(incident.building_id)

    case recipients do
      [] ->
        # Aucun syndic configuré sur ce bâtiment — on n'a rien à envoyer.
        # Pas un échec, juste rien à faire.
        :ok

      users ->
        email = build_email(incident, follower, message, users)
        Mailer.deliver(email)
        :ok
    end
  end

  defp syndic_recipients(building_id) do
    syndic_user_roles = [:syndic_manager, :syndic_staff]

    Ecto.Query.from(m in BuildingMember,
      join: u in User,
      on: u.id == m.user_id,
      where:
        m.building_id == ^building_id and
          m.is_active == true and
          u.role in ^syndic_user_roles,
      select: u,
      distinct: true
    )
    |> Repo.all()
  end

  defp build_email(incident, follower, message, recipients) do
    case_url = "#{base_url()}/cases/#{incident.id}"
    follower_name = display_name(follower)

    new()
    |> from({"Komun", "noreply@komun.app"})
    |> bcc(Enum.map(recipients, & &1.email))
    |> subject("[Komun] Relance dossier : #{incident.title}")
    |> html_body(build_html(incident, follower_name, message, case_url))
    |> text_body(build_text(incident, follower_name, message, case_url))
  end

  defp build_html(incident, follower_name, message, url) do
    EmailLayout.render(
      preheader: "Relance #{follower_name} sur « #{incident.title} »",
      body:
        EmailLayout.h1("Relance sur un dossier") <>
          EmailLayout.p(
            "<strong>#{EmailLayout.escape(follower_name)}</strong> vous relance sur le dossier <strong>#{EmailLayout.escape(incident.title)}</strong>."
          ) <>
          EmailLayout.p(
            ~s(<em style="white-space:pre-wrap">#{EmailLayout.escape(message)}</em>)
          ) <>
          EmailLayout.cta_button(url, "Ouvrir le dossier") <>
          EmailLayout.muted(
            "Vous recevez cet email car vous gérez ce bâtiment. Une seule relance par dossier est envoyée par tranche de 24h, même si plusieurs personnes relancent."
          )
    )
  end

  defp build_text(incident, follower_name, message, url) do
    """
    Relance sur un dossier

    #{follower_name} vous relance sur le dossier "#{incident.title}".

    Message :
    #{message}

    Ouvrir le dossier : #{url}

    Vous recevez cet email car vous gérez ce bâtiment. Une seule relance
    par dossier est envoyée par tranche de 24h, même si plusieurs
    personnes relancent.
    """
  end

  defp display_name(%User{first_name: f, last_name: l}) when is_binary(f) and is_binary(l) and f != "" and l != "" do
    "#{f} #{l}"
  end

  defp display_name(%User{email: email}), do: email

  defp base_url do
    System.get_env("APP_BASE_URL", @default_base_url)
  end
end
