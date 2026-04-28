defmodule KomunBackend.DoleancesLinkedIncidentTest do
  @moduledoc """
  Vérifie la liaison doléance → incident d'origine (« dégât signalé →
  passé en garantie → doléance collective »).

  Couvre :
  - `linked_incident_id` accepté à la création d'une doléance,
  - le champ persiste et est rechargé via `get_doleance!/1`,
  - `Doleances.list_by_incident/1` retourne la bonne sous-liste,
  - ON DELETE NILIFY côté DB : supprimer l'incident ne casse pas la
    doléance, on perd juste le rétro-lien.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Doleances, Incidents, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: :coproprietaire
    })
    |> Repo.insert!()
  end

  defp setup_context do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)
    {building, user}
  end

  defp create_incident!(building, user) do
    {:ok, inc} =
      Incidents.create_incident(building.id, user.id, %{
        "title" => "Fuite d'eau plomberie générale",
        "description" => "Trace d'humidité visible dans la cage d'escalier.",
        "category" => "plomberie"
      })

    inc
  end

  describe "create_doleance/3 with linked_incident_id" do
    test "persiste le lien quand linked_incident_id est fourni" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, d} =
        Doleances.create_doleance(building.id, user.id, %{
          "title" => "Garantie décennale plomberie",
          "description" => "La fuite récurrente passe en garantie.",
          "category" => "construction_defect",
          "linked_incident_id" => incident.id
        })

      assert d.linked_incident_id == incident.id

      reloaded = Doleances.get_doleance!(d.id)
      assert reloaded.linked_incident_id == incident.id
      assert reloaded.linked_incident.id == incident.id
      assert reloaded.linked_incident.title == incident.title
    end

    test "linked_incident_id reste nil si non fourni" do
      {building, user} = setup_context()

      {:ok, d} =
        Doleances.create_doleance(building.id, user.id, %{
          "title" => "Doléance indépendante",
          "description" => "Aucun incident à l'origine de cette doléance.",
          "category" => "autre"
        })

      assert is_nil(d.linked_incident_id)
    end
  end

  describe "list_by_incident/1" do
    test "ne retourne que les doléances rattachées à l'incident demandé" do
      {building, user} = setup_context()
      incident_a = create_incident!(building, user)
      incident_b = create_incident!(building, user)

      {:ok, d1} =
        Doleances.create_doleance(building.id, user.id, %{
          "title" => "Doléance suite incident A",
          "description" => "Détails complémentaires sur l'incident A.",
          "category" => "structure",
          "linked_incident_id" => incident_a.id
        })

      {:ok, _d_unrelated} =
        Doleances.create_doleance(building.id, user.id, %{
          "title" => "Doléance hors lien",
          "description" => "Aucun lien avec un incident.",
          "category" => "autre"
        })

      {:ok, _d_b} =
        Doleances.create_doleance(building.id, user.id, %{
          "title" => "Doléance suite incident B",
          "description" => "Détails complémentaires sur l'incident B.",
          "category" => "equipement",
          "linked_incident_id" => incident_b.id
        })

      results = Doleances.list_by_incident(incident_a.id)
      assert length(results) == 1
      assert hd(results).id == d1.id
    end
  end

  describe "ON DELETE NILIFY" do
    test "supprimer l'incident ne supprime pas la doléance, on perd juste le lien" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, d} =
        Doleances.create_doleance(building.id, user.id, %{
          "title" => "Doléance qui survit",
          "description" => "Doit survivre à la suppression de l'incident.",
          "category" => "autre",
          "linked_incident_id" => incident.id
        })

      assert d.linked_incident_id == incident.id

      Repo.delete!(incident)

      reloaded = Doleances.get_doleance!(d.id)
      assert reloaded.id == d.id
      assert is_nil(reloaded.linked_incident_id)
    end
  end
end
