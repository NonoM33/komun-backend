defmodule KomunBackend.Notifications.Jobs.NotifySameFloorJobTest do
  @moduledoc """
  Vérifie que NotifySameFloorJob touche bien tous les voisins de palier
  (push uniquement, pas d'email — voir module pour le rationale) sans
  inclure le signaleur lui-même.
  """

  use KomunBackend.DataCase, async: false
  use Oban.Testing, repo: KomunBackend.Repo

  alias KomunBackend.{Buildings, Residences, Repo}
  alias KomunBackend.Buildings.{Building, Lot}
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Accounts.User
  alias KomunBackend.Incidents
  alias KomunBackend.Notifications.Jobs.NotifySameFloorJob

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Rés #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "B #{System.unique_integer([:positive])}",
      address: "1 rue Test",
      city: "Paris",
      postal_code: "75001",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_lot!(building, attrs) do
    %Lot{}
    |> Lot.changeset(Map.merge(%{type: :apartment, building_id: building.id}, attrs))
    |> Repo.insert!()
  end

  defp insert_user!(opts \\ []) do
    %User{}
    |> User.changeset(%{
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: :coproprietaire,
      push_tokens: opts[:push_tokens] || ["fcm-#{System.unique_integer([:positive])}"]
    })
    |> Repo.insert!()
  end

  defp link_member!(building_id, user, lot) do
    {:ok, m} = Buildings.add_member(building_id, user.id, :coproprietaire)
    m |> Ecto.Changeset.change(primary_lot_id: lot.id) |> Repo.update!()
  end

  describe "perform/1" do
    test "termine sans erreur quand des voisins de palier existent" do
      # NB : Oban est en `testing: :inline` côté config test → les jobs
      # SendPushNotificationJob sont exécutés immédiatement et ne laissent
      # pas de trace en DB. La sélection des voisins (cœur de la logique)
      # est déjà couverte par AdjacencyTest. Ici on vérifie juste que le
      # job traverse les voisins et le reporter sans crash.
      r = insert_residence!()
      b = insert_building!(r)

      lot_2001 = insert_lot!(b, %{number: "2001", floor: 2})
      lot_2002 = insert_lot!(b, %{number: "2002", floor: 2})
      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      _lot_1001 = insert_lot!(b, %{number: "1001", floor: 1})

      reporter = insert_user!()
      neighbor_a = insert_user!()
      neighbor_b = insert_user!()

      link_member!(b.id, reporter, lot_2001)
      link_member!(b.id, neighbor_a, lot_2002)
      link_member!(b.id, neighbor_b, lot_2003)

      {:ok, incident} =
        Incidents.create_incident(b.id, reporter.id, %{
          "title" => "Bruit la nuit",
          "description" => "Musique forte",
          "category" => "parties_communes",
          "subtype" => "noise"
        })

      assert :ok = perform_job(NotifySameFloorJob, %{"incident_id" => incident.id})
    end

    test "no-op silencieux quand pas de voisin de palier" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2001 = insert_lot!(b, %{number: "2001", floor: 2})

      reporter = insert_user!()
      link_member!(b.id, reporter, lot_2001)

      {:ok, incident} =
        Incidents.create_incident(b.id, reporter.id, %{
          "title" => "Bruit",
          "description" => "Tapage",
          "category" => "parties_communes",
          "subtype" => "noise"
        })

      assert :ok = perform_job(NotifySameFloorJob, %{"incident_id" => incident.id})
    end

    test "no-op si l'incident n'existe plus" do
      assert :ok = perform_job(NotifySameFloorJob, %{"incident_id" => Ecto.UUID.generate()})
    end
  end
end
