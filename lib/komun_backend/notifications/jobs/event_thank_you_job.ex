defmodule KomunBackend.Notifications.Jobs.EventThankYouJob do
  @moduledoc """
  Email « merci d'être venu » envoyé J+1 aux participants qui ont RSVP
  `going`. Job programmé à la création de l'événement (cf.
  `Events.schedule_jobs/1`).

  Inclut un placeholder pour le lien photos souvenirs (PR3 — quand le
  feature sera live, on regénérera le lien dans cet email).
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias KomunBackend.{Events, Repo}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Events.{Event, EventEmailBlast}
  alias KomunBackend.Mailer
  alias KomunBackend.Notifications.EmailLayout

  import Swoosh.Email
  require Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      %Event{status: status} when status in [:cancelled, :draft] ->
        :ok

      event ->
        do_thank_you(event)
    end
  end

  defp do_thank_you(event) do
    full = Events.get_event!(event.id)

    going_user_ids =
      full.participations
      |> Enum.filter(&(&1.status == :going))
      |> Enum.map(& &1.user_id)

    if going_user_ids == [] do
      :ok
    else
      users = Ecto.Query.from(u in User, where: u.id in ^going_user_ids) |> Repo.all()

      Enum.each(users, fn u ->
        send_email(full, u)
      end)

      total = full.total_attendees_with_plus_ones || length(users)

      %EventEmailBlast{}
      |> EventEmailBlast.changeset(%{
        event_id: full.id,
        kind: :thank_you_j_plus_1,
        recipient_count: length(users),
        subject: "Merci pour #{full.title} — #{total} voisins étaient là"
      })
      |> Repo.insert()
    end
  end

  defp send_email(event, %User{email: email}) do
    new()
    |> to(email)
    |> from({"Komun", "noreply@komun.app"})
    |> subject("Merci pour #{event.title} 🎉")
    |> html_body(thank_you_html(event))
    |> text_body(thank_you_text(event))
    |> Mailer.deliver()

    :ok
  rescue
    _ -> :ok
  end

  defp thank_you_html(event) do
    EmailLayout.render(
      preheader: "Merci d'être venu — partagez vos meilleures photos !",
      body:
        EmailLayout.h1("Merci d'être venu à #{EmailLayout.escape(event.title)} 🎉") <>
          EmailLayout.p(
            "Nous étions <strong>#{event.total_attendees_with_plus_ones || event.participants_count} voisins</strong> à se retrouver — un beau moment de quartier."
          ) <>
          EmailLayout.p(
            "Partagez vos photos souvenirs avec les voisins qui étaient là (le lien sera bientôt disponible — feature en cours de finalisation)."
          ) <>
          EmailLayout.cta_button(
            "https://komun.app/events/#{event.id}",
            "Voir le récap de l'événement"
          ) <>
          EmailLayout.muted(
            "À bientôt pour le prochain événement de voisinage. — L'équipe Komun."
          )
    )
  end

  defp thank_you_text(event) do
    """
    Merci d'être venu à #{event.title} !

    Nous étions #{event.total_attendees_with_plus_ones || event.participants_count} voisins à se retrouver.

    Voir le récap : https://komun.app/events/#{event.id}

    À bientôt — L'équipe Komun.
    """
  end
end
