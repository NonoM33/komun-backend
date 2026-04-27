defmodule KomunBackend.Notifications.Jobs.NotifySameFloorJob do
  @moduledoc """
  Job déclenché à la création d'un incident de type `:noise`.

  Notifie tous les voisins de palier (apartments du même étage, sauf le
  signaleur lui-même) via push uniquement — pas d'email pour limiter le
  bruit et éviter le spam quand un incident bruit est ouvert tard le soir.

  Push neutre : on ne dit pas QUI a signalé (pas d'identification du
  voisin), juste qu'un signalement bruit a été fait sur leur étage.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias KomunBackend.Buildings.{Adjacency, BuildingMember, Lot}
  alias KomunBackend.Incidents.Incident
  alias KomunBackend.Notifications
  alias KomunBackend.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"incident_id" => incident_id}}) do
    with %Incident{} = incident <- Repo.get(Incident, incident_id),
         %Lot{} = reporter_lot <- reporter_lot(incident) do
      neighbors = Adjacency.same_floor_neighbors(reporter_lot)

      Enum.each(neighbors, fn neighbor_lot ->
        Adjacency.members_for_lot(neighbor_lot)
        |> Enum.each(&send_push(incident, reporter_lot, neighbor_lot, &1))
      end)

      :ok
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

  defp send_push(incident, _reporter_lot, neighbor_lot, member) do
    Notifications.send_to_user(
      member.user,
      "🔊 Bruit signalé sur votre étage",
      "Un voisin de votre étage vient de signaler des nuisances sonores.",
      %{
        type: "incident_neighbor_alert",
        subtype: "noise",
        incident_id: incident.id,
        building_id: incident.building_id,
        neighbor_lot_id: neighbor_lot.id
      }
    )
  end
end
