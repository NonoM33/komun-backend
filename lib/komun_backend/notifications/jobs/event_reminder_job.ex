defmodule KomunBackend.Notifications.Jobs.EventReminderJob do
  @moduledoc """
  Push + email envoyé J-1 aux participants qui ont RSVP `going` ou
  `maybe`. Programmé automatiquement à la création / publication de
  l'événement (cf. `Events.schedule_jobs/1`).

  Le job no-op silencieusement si :
    - l'event a été annulé entre la programmation et l'exécution,
    - l'event est en draft (jamais publié),
    - personne n'a RSVP.
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias KomunBackend.{Events, Notifications, Repo}
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

      %Event{status: status} = event when status in [:cancelled, :draft] ->
        log_no_op(event_id, :reminder_j1, "status=#{status}")
        :ok

      event ->
        do_reminder(event)
    end
  end

  defp do_reminder(event) do
    event = Events.get_event!(event.id)

    recipients =
      event.participations
      |> Enum.filter(fn p -> p.status in [:going, :maybe] end)
      |> Enum.map(& &1.user_id)

    if recipients == [] do
      log_no_op(event.id, :reminder_j1, "no_rsvp")
      :ok
    else
      users = fetch_users(recipients)

      Enum.each(users, fn u ->
        send_push(event, u)
        send_email(event, u)
      end)

      log_blast(event.id, :reminder_j1, length(users), reminder_subject(event))
      :ok
    end
  end

  defp fetch_users(ids) do
    Ecto.Query.from(u in User, where: u.id in ^ids) |> Repo.all()
  end

  defp send_push(event, %User{push_tokens: tokens} = user)
       when is_list(tokens) and tokens != [] do
    Notifications.send_to_user(
      user,
      "C'est demain : #{event.title}",
      reminder_push_body(event),
      %{type: "event_reminder", event_id: event.id}
    )
  end

  defp send_push(_event, _user), do: :ok

  defp reminder_push_body(event) do
    "Rendez-vous #{format_time(event.starts_at)} — #{event.location_label || "(lieu à confirmer)"}"
  end

  defp send_email(event, %User{email: email}) do
    new()
    |> to(email)
    |> from({"Komun", "noreply@komun.app"})
    |> subject(reminder_subject(event))
    |> html_body(reminder_html(event))
    |> text_body(reminder_text(event))
    |> Mailer.deliver()

    :ok
  rescue
    _ -> :ok
  end

  defp reminder_subject(event), do: "Rappel J-1 — #{event.title}"

  defp reminder_html(event) do
    EmailLayout.render(
      preheader: "C'est demain ! On vous attend.",
      body:
        EmailLayout.h1("C'est demain : #{EmailLayout.escape(event.title)}") <>
          EmailLayout.p(
            "Petit rappel : votre événement de voisinage commence demain, " <>
              format_time(event.starts_at) <>
              ", à <strong>#{EmailLayout.escape(event.location_label || "(lieu à confirmer)")}</strong>."
          ) <>
          maybe_description(event) <>
          EmailLayout.cta_button("https://komun.app/events/#{event.id}", "Voir l'événement") <>
          EmailLayout.muted(
            "Vous recevez cet email parce que vous avez RSVP à un événement de votre résidence."
          )
    )
  end

  defp reminder_text(event) do
    """
    Rappel J-1 — #{event.title}

    C'est demain ! Rendez-vous #{format_time(event.starts_at)} à #{event.location_label || "(lieu à confirmer)"}.

    Voir l'événement : https://komun.app/events/#{event.id}
    """
  end

  defp maybe_description(%Event{description: nil}), do: ""
  defp maybe_description(%Event{description: ""}), do: ""

  defp maybe_description(%Event{description: desc}),
    do: EmailLayout.p(EmailLayout.escape(desc))

  defp format_time(%DateTime{} = dt) do
    # Format "vendredi 17 mai à 18:00" — minimal, on évite Timex pour
    # ne pas ajouter une dépendance pour un seul format. Locale fr en
    # dur — la cible est francophone.
    days = ~w(lundi mardi mercredi jeudi vendredi samedi dimanche)

    months = ~w(janvier février mars avril mai juin juillet août
                septembre octobre novembre décembre)

    iso_day = Date.day_of_week(DateTime.to_date(dt))
    "#{Enum.at(days, iso_day - 1)} #{dt.day} #{Enum.at(months, dt.month - 1)} à #{pad(dt.hour)}h#{pad(dt.minute)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp log_blast(event_id, kind, count, subject) do
    %EventEmailBlast{}
    |> EventEmailBlast.changeset(%{
      event_id: event_id,
      kind: kind,
      recipient_count: count,
      subject: subject
    })
    |> Repo.insert()
  end

  defp log_no_op(event_id, kind, reason) do
    require Logger
    Logger.info("[event_reminder] no-op event=#{event_id} kind=#{kind} reason=#{reason}")
    :ok
  end
end
