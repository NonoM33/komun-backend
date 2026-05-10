defmodule KomunBackend.Notifications.Jobs.NotifyCouncilOfBookingJob do
  @moduledoc """
  Envoie un email à chaque membre du conseil syndical (et du syndic) du
  bâtiment quand une nouvelle demande de réservation de ressource
  commune est déposée.

  L'utilisateur a fourni un préavis (48h par défaut pour l'ascenseur),
  donc le timing n'est pas critique — on tolère le décalage Oban et la
  livraison best-effort. Trois retries avec backoff suffisent.
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  alias KomunBackend.{CommonResources, Mailer, Repo}
  alias KomunBackend.CommonResources.{Booking, Resource}
  alias KomunBackend.Notifications.EmailLayout
  import Swoosh.Email

  @default_base_url "https://komun.app"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_id" => booking_id, "building_id" => building_id}}) do
    booking = Repo.get(Booking, booking_id) |> Repo.preload([:common_resource, :requester])

    case booking do
      nil ->
        # Le booking a été supprimé entre l'enqueue et l'exécution. No-op.
        :ok

      %Booking{} ->
        validators = CommonResources.list_validators_for_building(building_id)

        Enum.each(validators, fn user ->
          if is_binary(user.email) and user.email != "" do
            send_email(user, booking)
          end
        end)

        :ok
    end
  end

  defp send_email(recipient, %Booking{} = booking) do
    %Resource{} = resource = booking.common_resource
    requester_label = format_requester(booking.requester)
    period = format_period(booking.starts_at, booking.ends_at)
    review_url = "#{base_url()}/conseil/reservations"

    new()
    |> to(recipient.email)
    |> from({"Komun", "noreply@komun.app"})
    |> subject("Nouvelle demande de réservation : #{resource.name}")
    |> html_body(build_html(requester_label, resource, period, booking.reason, review_url))
    |> text_body(build_text(requester_label, resource, period, booking.reason, review_url))
    |> Mailer.deliver()
  end

  defp format_requester(%{first_name: f, last_name: l})
       when is_binary(f) and is_binary(l) and f != "" and l != "" do
    "#{f} #{l}"
  end

  defp format_requester(%{email: email}) when is_binary(email), do: email
  defp format_requester(_), do: "Un résident"

  defp format_period(%DateTime{} = s, %DateTime{} = e) do
    s_local = shift(s)
    e_local = shift(e)
    "du #{format_dt(s_local)} au #{format_dt(e_local)}"
  end

  defp shift(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Europe/Paris") do
      {:ok, local} -> local
      _ -> dt
    end
  end

  # « 09/05/2026 à 14h30 »
  defp format_dt(%DateTime{} = dt) do
    "#{pad(dt.day)}/#{pad(dt.month)}/#{dt.year} à #{pad(dt.hour)}h#{pad(dt.minute)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  defp build_html(requester, %Resource{} = r, period, reason, review_url) do
    EmailLayout.render(
      preheader: "Une réservation est en attente de votre validation.",
      body:
        EmailLayout.h1("Nouvelle demande de réservation") <>
          EmailLayout.p(
            "<strong>#{EmailLayout.escape(requester)}</strong> a demandé à utiliser " <>
              "<strong>#{EmailLayout.escape(r.name)}</strong> #{EmailLayout.escape(period)}."
          ) <>
          reason_block(reason) <>
          EmailLayout.cta_button(review_url, "Examiner la demande") <>
          EmailLayout.muted(
            "N'importe quel membre du conseil syndical peut approuver ou refuser. La première réponse fait foi."
          )
    )
  end

  defp reason_block(nil), do: ""
  defp reason_block(""), do: ""

  defp reason_block(reason) when is_binary(reason) do
    EmailLayout.p("Motif indiqué : « #{EmailLayout.escape(reason)} »")
  end

  defp build_text(requester, %Resource{} = r, period, reason, review_url) do
    reason_text =
      case reason do
        s when is_binary(s) and s != "" -> "Motif : #{s}\n\n"
        _ -> ""
      end

    """
    Nouvelle demande de réservation

    #{requester} a demandé à utiliser #{r.name} #{period}.

    #{reason_text}Pour examiner la demande :
    #{review_url}

    N'importe quel membre du conseil syndical peut approuver ou refuser.
    La première réponse fait foi.
    """
  end

  defp base_url do
    System.get_env("APP_BASE_URL", @default_base_url)
  end
end
