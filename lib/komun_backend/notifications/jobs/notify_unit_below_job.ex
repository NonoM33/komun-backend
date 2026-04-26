defmodule KomunBackend.Notifications.Jobs.NotifyUnitBelowJob do
  @moduledoc """
  Job déclenché à la création d'un incident de type `:water_leak`.

  Trouve le logement directement en dessous du logement du `reporter` et
  envoie un email + push aux membres actifs de ce logement, leur demandant
  de vérifier rapidement leurs plafonds. Délai d'action court → priorité
  haute (queue `:emails`).

  Si l'incident est `:council_only`, ce job n'est PAS enqueue (l'identité
  du signaleur reste confidentielle).
  """

  use Oban.Worker, queue: :emails, max_attempts: 3

  import Ecto.Query
  # `Swoosh.Email.from/2` clashes avec `Ecto.Query.from/2` — on se contente
  # de `new/0` puis on appelle les builders en pipeline (to/2, subject/2…).
  import Swoosh.Email, only: [new: 0, to: 2, subject: 2, html_body: 2, text_body: 2]

  alias KomunBackend.Buildings.{Adjacency, BuildingMember, Lot}
  alias KomunBackend.Incidents.Incident
  alias KomunBackend.Mailer
  alias KomunBackend.Notifications
  alias KomunBackend.Notifications.EmailLayout
  alias KomunBackend.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"incident_id" => incident_id}}) do
    with %Incident{} = incident <- Repo.get(Incident, incident_id),
         %Lot{} = reporter_lot <- reporter_lot(incident),
         %Lot{} = below <- Adjacency.unit_below(reporter_lot) do
      notify_members(incident, reporter_lot, below)
    else
      _ -> :ok
    end
  end

  defp reporter_lot(%Incident{reporter_id: nil}), do: nil

  defp reporter_lot(%Incident{reporter_id: rid, building_id: bid}) do
    from(m in BuildingMember,
      where: m.user_id == ^rid and m.building_id == ^bid and m.is_active == true,
      preload: [:primary_lot]
    )
    |> Repo.one()
    |> case do
      nil -> nil
      %BuildingMember{primary_lot: %Lot{} = lot} -> lot
      _ -> nil
    end
  end

  defp notify_members(%Incident{} = incident, reporter_lot, %Lot{} = below) do
    members = Adjacency.members_for_lot(below)

    Enum.each(members, fn member ->
      send_push(incident, reporter_lot, below, member)
      send_email(incident, reporter_lot, below, member)
    end)

    :ok
  end

  defp send_push(incident, reporter_lot, below, member) do
    Notifications.send_to_user(
      member.user,
      "⚠️ Dégât des eaux signalé au-dessus",
      "Le logement #{reporter_lot.number} a signalé un dégât des eaux. Vérifiez vos plafonds.",
      %{
        type: "incident_neighbor_alert",
        subtype: "water_leak",
        incident_id: incident.id,
        building_id: incident.building_id,
        reporter_lot_id: reporter_lot.id,
        below_lot_id: below.id
      }
    )
  end

  defp send_email(_incident, _reporter_lot, _below, %{user: %{email: nil}}), do: :ok

  defp send_email(incident, reporter_lot, below, member) do
    new()
    |> to(member.user.email)
    |> Swoosh.Email.from({"Komun", "noreply@komun.app"})
    |> subject("⚠️ Dégât des eaux signalé au-dessus de chez vous (logement #{reporter_lot.number})")
    |> html_body(build_html(incident, reporter_lot, below))
    |> text_body(build_text(incident, reporter_lot, below))
    |> Mailer.deliver()

    :ok
  end

  defp build_text(incident, reporter_lot, below) do
    """
    Dégât des eaux signalé au logement #{reporter_lot.number}

    Bonjour,

    Un dégât des eaux a été signalé dans le logement #{reporter_lot.number}, situé
    juste au-dessus de votre logement (#{below.number}).

    Pour limiter les dégâts, prenez le temps de vérifier rapidement vos
    plafonds, gaines techniques et conduites apparentes — surtout dans la
    cuisine, la salle de bain et les WC.

    Détail signalé : #{incident.title}

    Si vous constatez quelque chose, signalez-le à votre tour depuis l'app
    Komun pour que le syndic soit informé immédiatement.
    """
  end

  defp build_html(incident, reporter_lot, below) do
    EmailLayout.render(
      preheader:
        "Dégât des eaux signalé juste au-dessus de chez vous — vérifiez vos plafonds.",
      body:
        EmailLayout.h1("⚠️ Dégât des eaux au-dessus de chez vous") <>
          EmailLayout.p(
            "Le logement <strong>#{EmailLayout.escape(reporter_lot.number)}</strong> a signalé un dégât des eaux. Votre logement (<strong>#{EmailLayout.escape(below.number)}</strong>) est situé directement en dessous."
          ) <>
          EmailLayout.p(
            "Vérifiez rapidement vos plafonds, gaines techniques et conduites — surtout dans la cuisine, la salle de bain et les WC."
          ) <>
          EmailLayout.p(
            "<em>Détail signalé :</em> #{EmailLayout.escape(incident.title)}"
          ) <>
          EmailLayout.muted(
            "Si vous constatez quelque chose, signalez-le à votre tour depuis l'app Komun pour que le syndic soit informé immédiatement."
          )
    )
  end
end
