defmodule KomunBackend.DiligencesTest do
  @moduledoc """
  Tests du contexte Diligences (procédure encadrée pour troubles
  anormaux du voisinage). On vérifie ici les invariants critiques :

  - Création d'une diligence ⇒ 9 `diligence_steps` créés en transaction
  - Update d'un step calcule correctement `completed_at` (set/clear)
  - Le numéro de step est borné à 1..9
  - `privileged?/2` aligne sur les rôles attendus
  - Le filtrage par status / linked_incident_id fonctionne
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Diligences, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Diligences.{Diligence, DiligenceStep, Steps}
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

  defp setup_building_and_president do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)
    {building, user}
  end

  describe "Steps module" do
    test "expose 9 étapes ordonnées 1..9" do
      assert Steps.count() == 9
      assert Steps.numbers() == Enum.to_list(1..9)
    end

    test "valid_number?/1 borne à 1..9" do
      assert Steps.valid_number?(1)
      assert Steps.valid_number?(9)
      refute Steps.valid_number?(0)
      refute Steps.valid_number?(10)
      refute Steps.valid_number?("3")
      refute Steps.valid_number?(nil)
    end

    test "title/1 retourne nil pour un step invalide" do
      assert is_binary(Steps.title(1))
      assert is_binary(Steps.title(9))
      assert Steps.title(99) == nil
    end
  end

  describe "create_diligence/3" do
    test "crée une diligence ET ses 9 steps en transaction" do
      {building, user} = setup_building_and_president()

      {:ok, %Diligence{} = d} =
        Diligences.create_diligence(building.id, user, %{
          "title" => "Odeurs cannabis lot 14",
          "description" => "Plaintes répétées de plusieurs résidents.",
          "source_type" => "copro_owner",
          "source_label" => "M. Untel, lot 14"
        })

      assert d.title == "Odeurs cannabis lot 14"
      assert d.status == :open
      assert d.source_type == :copro_owner
      assert d.created_by_id == user.id
      assert d.building_id == building.id

      # Les 9 steps sont créés et en `pending`.
      assert length(d.steps) == 9

      step_numbers = Enum.map(d.steps, & &1.step_number) |> Enum.sort()
      assert step_numbers == Enum.to_list(1..9)

      assert Enum.all?(d.steps, &(&1.status == :pending))
      assert Enum.all?(d.steps, &is_nil(&1.completed_at))
    end

    test "ignore building_id et created_by_id passés dans attrs (verrou)" do
      {building, user} = setup_building_and_president()
      other_user = insert_user!(:syndic_manager)

      {:ok, d} =
        Diligences.create_diligence(building.id, user, %{
          "title" => "Sujet test sécurité",
          # Tentative de spoof : ne doit pas écraser les valeurs
          # imposées par le contexte.
          "building_id" => Ecto.UUID.generate(),
          "created_by_id" => other_user.id
        })

      assert d.building_id == building.id
      assert d.created_by_id == user.id
    end

    test "rejette un titre trop court" do
      {building, user} = setup_building_and_president()

      assert {:error, %Ecto.Changeset{} = cs} =
               Diligences.create_diligence(building.id, user, %{"title" => "abc"})

      assert "should be at least 5 character(s)" in errors_on(cs).title
    end

    test "accepte le lien optionnel vers un incident existant" do
      {building, user} = setup_building_and_president()

      incident =
        %KomunBackend.Incidents.Incident{}
        |> KomunBackend.Incidents.Incident.changeset(%{
          title: "Incident lié",
          description: "desc",
          category: :autre,
          building_id: building.id,
          reporter_id: user.id
        })
        |> Repo.insert!()

      {:ok, d} =
        Diligences.create_diligence(building.id, user, %{
          "title" => "Diligence avec lien",
          "linked_incident_id" => incident.id
        })

      assert d.linked_incident_id == incident.id
    end
  end

  describe "update_step/3" do
    test "passe un step à completed et set completed_at" do
      {building, user} = setup_building_and_president()
      {:ok, d} = Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      assert {:ok, %DiligenceStep{} = step} =
               Diligences.update_step(d.id, 1, %{
                 "status" => "completed",
                 "notes" => "Rôles cadrés en réunion CS du 28 avril."
               })

      assert step.status == :completed
      assert step.notes =~ "réunion CS"
      refute is_nil(step.completed_at)
    end

    test "clear completed_at quand on revient à in_progress" do
      {building, user} = setup_building_and_president()
      {:ok, d} = Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      {:ok, _} = Diligences.update_step(d.id, 2, %{"status" => "completed"})
      {:ok, step} = Diligences.update_step(d.id, 2, %{"status" => "in_progress"})

      assert step.status == :in_progress
      assert is_nil(step.completed_at)
    end

    test "rejette un step_number hors plage 1..9" do
      {building, user} = setup_building_and_president()
      {:ok, d} = Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      assert {:error, :invalid_step_number} =
               Diligences.update_step(d.id, 99, %{"status" => "completed"})

      assert {:error, :invalid_step_number} =
               Diligences.update_step(d.id, 0, %{"status" => "completed"})
    end

    test "renvoie :not_found pour un step_number valide mais une diligence inexistante" do
      assert {:error, :not_found} =
               Diligences.update_step(Ecto.UUID.generate(), 3, %{"status" => "completed"})
    end
  end

  describe "list_diligences/2" do
    test "filtre par status" do
      {building, user} = setup_building_and_president()
      {:ok, d1} = Diligences.create_diligence(building.id, user, %{"title" => "Diligence 1"})
      {:ok, d2} = Diligences.create_diligence(building.id, user, %{"title" => "Diligence 2"})

      {:ok, _} = Diligences.update_diligence(d2, %{"status" => "closed"})

      open_ids =
        Diligences.list_diligences(building.id, %{"status" => "open"})
        |> Enum.map(& &1.id)

      assert d1.id in open_ids
      refute d2.id in open_ids
    end

    test "isole les diligences par bâtiment" do
      {building_a, user_a} = setup_building_and_president()
      {building_b, user_b} = setup_building_and_president()

      {:ok, d_a} =
        Diligences.create_diligence(building_a.id, user_a, %{"title" => "Sujet A"})

      {:ok, _d_b} =
        Diligences.create_diligence(building_b.id, user_b, %{"title" => "Sujet B"})

      ids_a =
        Diligences.list_diligences(building_a.id) |> Enum.map(& &1.id)

      assert d_a.id in ids_a
      assert length(ids_a) == 1
    end
  end

  describe "privileged?/2" do
    test "true pour super_admin global, indépendamment du bâtiment" do
      residence = insert_residence!()
      building = insert_building!(residence)
      admin = insert_user!(:super_admin)

      assert Diligences.privileged?(building.id, admin)
    end

    test "true pour president_cs membre du bâtiment" do
      {building, user} = setup_building_and_president()
      assert Diligences.privileged?(building.id, user)
    end

    test "false pour un copropriétaire standard" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      refute Diligences.privileged?(building.id, user)
    end

    test "false pour un user non membre du bâtiment" do
      residence = insert_residence!()
      building = insert_building!(residence)
      stranger = insert_user!()
      refute Diligences.privileged?(building.id, stranger)
    end

    test "false quand user est nil" do
      refute Diligences.privileged?(Ecto.UUID.generate(), nil)
    end
  end

  describe "set_letter/3" do
    test "persiste un courrier saisine syndic" do
      {building, user} = setup_building_and_president()
      {:ok, d} = Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      assert {:ok, updated} = Diligences.set_letter(d, :saisine, "Texte du courrier...")
      assert updated.saisine_syndic_letter == "Texte du courrier..."
      assert is_nil(updated.mise_en_demeure_letter)
    end

    test "persiste un courrier mise en demeure" do
      {building, user} = setup_building_and_president()
      {:ok, d} = Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      assert {:ok, updated} = Diligences.set_letter(d, :mise_en_demeure, "Mise en demeure...")
      assert updated.mise_en_demeure_letter == "Mise en demeure..."
    end
  end
end
