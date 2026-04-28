defmodule KomunBackend.ProjectsLinkedCasesTest do
  @moduledoc """
  Tests autour de la liaison projet ↔ dossier (incident / doléance /
  diligence). On vérifie ici :

  - le changeset accepte les 3 FK quand elles sont valides,
  - il refuse plusieurs liens simultanés (au plus 1 dossier source),
  - les helpers `list_projects_linked_to_*` filtrent correctement,
  - le filtre `linked_*_id` sur `list_projects/2` renvoie la bonne sous-liste.

  Les FK sont nullable + ON DELETE SET NULL : si on supprime le dossier
  source, le projet survit, on perd juste le rattachement. C'est testé
  ici aussi pour éviter une régression silencieuse côté migration.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Doleances, Incidents, Projects, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Diligences
  alias KomunBackend.Projects.Project
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

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
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

  defp create_doleance!(building, user) do
    {:ok, d} =
      Doleances.create_doleance(building.id, user.id, %{
        "title" => "Défaut de construction sur la façade",
        "description" => "Fissures verticales apparues après un an.",
        "category" => "construction_defect"
      })

    d
  end

  defp create_diligence!(building, user) do
    {:ok, dil} =
      Diligences.create_diligence(building.id, user, %{
        "title" => "Trouble anormal du voisinage cannabis",
        "description" => "Odeurs récurrentes et plaintes croisées."
      })

    dil
  end

  describe "Project.changeset/2 — linked cases" do
    test "accepte un linked_incident_id valide" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      cs =
        Project.changeset(%Project{}, %{
          "title" => "Devis plomberie urgente",
          "building_id" => building.id,
          "linked_incident_id" => incident.id
        })

      assert cs.valid?
    end

    test "accepte un linked_doleance_id valide" do
      {building, user} = setup_context()
      doleance = create_doleance!(building, user)

      cs =
        Project.changeset(%Project{}, %{
          "title" => "Devis ravalement façade",
          "building_id" => building.id,
          "linked_doleance_id" => doleance.id
        })

      assert cs.valid?
    end

    test "accepte 0 lien (projet libre, sans dossier source)" do
      {building, _user} = setup_context()

      cs =
        Project.changeset(%Project{}, %{
          "title" => "Projet ouvert",
          "building_id" => building.id
        })

      assert cs.valid?
    end

    test "refuse 2 liens simultanés (incident + doléance)" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)
      doleance = create_doleance!(building, user)

      cs =
        Project.changeset(%Project{}, %{
          "title" => "Projet trop lié",
          "building_id" => building.id,
          "linked_incident_id" => incident.id,
          "linked_doleance_id" => doleance.id
        })

      refute cs.valid?
      assert {_msg, _} = cs.errors[:linked_incident_id]
    end

    test "refuse 3 liens simultanés (incident + doléance + diligence)" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)
      doleance = create_doleance!(building, user)
      diligence = create_diligence!(building, user)

      cs =
        Project.changeset(%Project{}, %{
          "title" => "Projet ultra lié",
          "building_id" => building.id,
          "linked_incident_id" => incident.id,
          "linked_doleance_id" => doleance.id,
          "linked_diligence_id" => diligence.id
        })

      refute cs.valid?
    end
  end

  describe "Projects.create_project/3 + list_projects/2" do
    test "crée un projet rattaché à un incident et le retrouve via le filtre" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, project} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Devis fuite urgente",
          "linked_incident_id" => incident.id
        })

      assert project.linked_incident_id == incident.id
      assert project.linked_doleance_id == nil
      assert project.linked_diligence_id == nil

      # Le preload doit être présent dans le résultat de get_project!
      assert %{id: id} = project.linked_incident
      assert id == incident.id

      # Filtre côté liste
      filtered = Projects.list_projects(building.id, %{"linked_incident_id" => incident.id})
      assert length(filtered) == 1
      assert hd(filtered).id == project.id

      # Sans filtre → toujours retourné
      all = Projects.list_projects(building.id)
      assert Enum.any?(all, &(&1.id == project.id))
    end

    test "crée un projet sans lien et n'apparaît pas dans la liste filtrée" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, _project} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Projet sans dossier"
        })

      filtered = Projects.list_projects(building.id, %{"linked_incident_id" => incident.id})
      assert filtered == []
    end

    test "list_projects_linked_to_incident/1 ramène uniquement les projets liés" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, linked} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Devis lié",
          "linked_incident_id" => incident.id
        })

      {:ok, _free} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Devis libre"
        })

      result = Projects.list_projects_linked_to_incident(incident.id)
      ids = Enum.map(result, & &1.id)
      assert ids == [linked.id]
    end

    test "rattache un projet existant via update_project (linkage a posteriori)" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, project} =
        Projects.create_project(building.id, user.id, %{"title" => "Projet libre au départ"})

      assert project.linked_incident_id == nil

      {:ok, updated} =
        Projects.update_project(project, %{"linked_incident_id" => incident.id})

      assert updated.linked_incident_id == incident.id
      assert updated.linked_incident.id == incident.id
    end

    test "ON DELETE SET NULL : suppression de l'incident garde le projet sans lien" do
      {building, user} = setup_context()
      incident = create_incident!(building, user)

      {:ok, project} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Devis lié à un incident bientôt supprimé",
          "linked_incident_id" => incident.id
        })

      Repo.delete!(incident)

      reloaded = Projects.get_project!(building.id, project.id)
      assert reloaded.linked_incident_id == nil
      # Le projet survit avec ses devis (ici 0).
      assert reloaded.title == "Devis lié à un incident bientôt supprimé"
    end
  end

  describe "Projects.list_projects_linked_to_doleance/1 et linked_to_diligence/1" do
    test "filtre par doléance" do
      {building, user} = setup_context()
      doleance = create_doleance!(building, user)

      {:ok, p} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Devis lié à une doléance",
          "linked_doleance_id" => doleance.id
        })

      assert [%{id: id}] = Projects.list_projects_linked_to_doleance(doleance.id)
      assert id == p.id
    end

    test "filtre par diligence" do
      {building, user} = setup_context()
      diligence = create_diligence!(building, user)

      {:ok, p} =
        Projects.create_project(building.id, user.id, %{
          "title" => "Devis lié à une diligence",
          "linked_diligence_id" => diligence.id
        })

      assert [%{id: id}] = Projects.list_projects_linked_to_diligence(diligence.id)
      assert id == p.id
    end
  end
end
