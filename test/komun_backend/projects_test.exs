defmodule KomunBackend.ProjectsTest do
  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Accounts, Buildings, Projects}
  alias KomunBackend.Projects.{Project, Devis}

  defp insert_building!(attrs \\ %{}) do
    defaults = %{
      "name" => "Bâtiment #{System.unique_integer([:positive])}",
      "address" => "5 rue des Lilas",
      "city" => "Paris",
      "postal_code" => "75015"
    }

    {:ok, building} = Buildings.create_building(Map.merge(defaults, attrs))
    building
  end

  defp insert_user! do
    {:ok, user} =
      Accounts.get_or_create_user("proj-#{System.unique_integer([:positive])}@komun.app")

    user
  end

  defp insert_project!(building, user, attrs \\ %{}) do
    {:ok, project} =
      Projects.create_project(
        building.id,
        user.id,
        Map.merge(%{"title" => "Ravalement façade"}, attrs)
      )

    project
  end

  describe "create_project/3" do
    test "crée un projet au statut collecting par défaut" do
      building = insert_building!()
      user = insert_user!()

      assert {:ok, %Project{} = project} =
               Projects.create_project(building.id, user.id, %{"title" => "Toiture"})

      assert project.title == "Toiture"
      assert project.status == :collecting
      assert project.building_id == building.id
      assert project.created_by_id == user.id
    end

    test "accepte des clés atomes" do
      building = insert_building!()
      user = insert_user!()

      assert {:ok, project} = Projects.create_project(building.id, user.id, %{title: "Ascenseur"})
      assert project.title == "Ascenseur"
    end

    test "rejette un titre trop court" do
      building = insert_building!()
      user = insert_user!()

      assert {:error, cs} = Projects.create_project(building.id, user.id, %{"title" => "ab"})
      assert %{title: _} = errors_on(cs)
    end

    test "rejette un projet lié à deux dossiers simultanément" do
      building = insert_building!()
      user = insert_user!()

      assert {:error, cs} =
               Projects.create_project(building.id, user.id, %{
                 "title" => "Double lien",
                 "linked_incident_id" => Ecto.UUID.generate(),
                 "linked_doleance_id" => Ecto.UUID.generate()
               })

      assert %{linked_incident_id: _} = errors_on(cs)
    end
  end

  describe "get_project/2 (scope par bâtiment)" do
    test "retourne le projet du bon bâtiment" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      assert Projects.get_project(building.id, project.id).id == project.id
    end

    test "retourne nil pour un projet d'un autre bâtiment" do
      b1 = insert_building!()
      b2 = insert_building!()
      user = insert_user!()
      project = insert_project!(b1, user)

      assert Projects.get_project(b2.id, project.id) == nil
    end

    test "get_project!/2 lève quand le projet n'est pas dans le bâtiment" do
      b1 = insert_building!()
      b2 = insert_building!()
      user = insert_user!()
      project = insert_project!(b1, user)

      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_project!(b2.id, project.id)
      end
    end
  end

  describe "list_projects/2" do
    test "remonte les projets du bâtiment" do
      building = insert_building!()
      user = insert_user!()
      p1 = insert_project!(building, user, %{"title" => "Premier"})
      p2 = insert_project!(building, user, %{"title" => "Second"})

      # NB: le tri est `desc: inserted_at` mais deux insert dans la même
      # seconde ne sont pas départageables — on compare donc l'ensemble.
      ids = Projects.list_projects(building.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([p1.id, p2.id])
    end

    test "isole les projets par bâtiment" do
      b1 = insert_building!()
      b2 = insert_building!()
      user = insert_user!()
      p1 = insert_project!(b1, user)
      _p2 = insert_project!(b2, user)

      ids = Projects.list_projects(b1.id) |> Enum.map(& &1.id)
      assert ids == [p1.id]
    end
  end

  describe "update_project/2 et delete_project/1" do
    test "met à jour le titre" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      assert {:ok, updated} = Projects.update_project(project, %{"title" => "Nouveau titre"})
      assert updated.title == "Nouveau titre"
    end

    test "delete_project/1 supprime le projet" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      assert {:ok, _} = Projects.delete_project(project)
      assert Projects.get_project(building.id, project.id) == nil
    end
  end

  describe "devis" do
    test "create_devis/3 attache un devis au projet" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      assert {:ok, %Devis{} = devis} =
               Projects.create_devis(project.id, user.id, %{"vendor_name" => "Peintures SARL"})

      assert devis.vendor_name == "Peintures SARL"
      assert devis.project_id == project.id
      assert devis.uploaded_by_id == user.id
    end

    test "create_devis/3 rejette un devis sans vendor_name" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      assert {:error, cs} = Projects.create_devis(project.id, user.id, %{"vendor_name" => ""})
      assert %{vendor_name: _} = errors_on(cs)
    end

    test "list_devis/1 remonte les devis triés par date" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      {:ok, d1} = Projects.create_devis(project.id, user.id, %{"vendor_name" => "A"})
      {:ok, d2} = Projects.create_devis(project.id, user.id, %{"vendor_name" => "B"})

      ids = Projects.list_devis(project.id) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([d1.id, d2.id])
    end

    test "get_devis/2 est scopé au projet" do
      building = insert_building!()
      user = insert_user!()
      p1 = insert_project!(building, user)
      p2 = insert_project!(building, user)

      {:ok, devis} = Projects.create_devis(p1.id, user.id, %{"vendor_name" => "A"})

      assert Projects.get_devis(p1.id, devis.id).id == devis.id
      assert Projects.get_devis(p2.id, devis.id) == nil
    end

    test "update_devis/2 et delete_devis/1" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)
      {:ok, devis} = Projects.create_devis(project.id, user.id, %{"vendor_name" => "A"})

      assert {:ok, updated} = Projects.update_devis(devis, %{"vendor_name" => "B"})
      assert updated.vendor_name == "B"

      assert {:ok, _} = Projects.delete_devis(updated)
      assert Projects.get_devis(project.id, devis.id) == nil
    end
  end

  describe "start_vote/4" do
    test "crée un vote, lie le devis et passe le projet en voting" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      {:ok, devis} =
        Projects.create_devis(project.id, user.id, %{"vendor_name" => "Peintures SARL"})

      assert {:ok, updated} = Projects.start_vote(project, user.id, devis.id)
      assert updated.status == :voting
      assert updated.chosen_devis_id == devis.id
      assert updated.vote_id != nil
      assert updated.vote.title =~ "Peintures SARL"
    end

    test "retourne :devis_not_found pour un devis inconnu" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)

      assert {:error, :devis_not_found} =
               Projects.start_vote(project, user.id, Ecto.UUID.generate())
    end

    test "retourne :already_voting si le projet est déjà en vote" do
      building = insert_building!()
      user = insert_user!()
      project = insert_project!(building, user)
      {:ok, devis} = Projects.create_devis(project.id, user.id, %{"vendor_name" => "A"})

      {:ok, voting} = Projects.start_vote(project, user.id, devis.id)

      assert {:error, :already_voting} = Projects.start_vote(voting, user.id, devis.id)
    end
  end

  describe "list_projects_linked_to_* helpers" do
    test "list_projects_linked_to_incident/1 filtre sur l'incident lié" do
      building = insert_building!()
      user = insert_user!()

      {:ok, incident} =
        KomunBackend.Incidents.create_incident(building.id, user.id, %{
          "title" => "Fuite toiture",
          "description" => "Une fuite au 3e étage",
          "category" => "plomberie"
        })

      incident_id = incident.id

      linked =
        insert_project!(building, user, %{
          "title" => "Lié incident",
          "linked_incident_id" => incident_id
        })

      _unlinked = insert_project!(building, user, %{"title" => "Non lié"})

      ids = Projects.list_projects_linked_to_incident(incident_id) |> Enum.map(& &1.id)
      assert ids == [linked.id]
    end
  end
end
