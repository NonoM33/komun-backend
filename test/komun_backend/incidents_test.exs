defmodule KomunBackend.IncidentsTest do
  @moduledoc """
  Tests unitaires du contexte Incidents (signalements scoped par bâtiment).

  On couvre ici les fonctions publiques réellement exposées :

  - CRUD nominal (`create_incident/3`, `get_incident/1`, `get_incident!/1`,
    `update_incident/2`)
  - Transitions de statut (brouillon → open → resolved via
    `resolve_incident/2`)
  - Confidentialité `:council_only` vs `:standard` et brouillons dans
    `list_incidents/3`
  - `privileged?/2` aligné sur les rôles attendus
  - Le flux "réponse IA" (`confirm_ai_answer`, `unconfirm_ai_answer`,
    `update_ai_answer`)
  - Commentaires (`add_comment/3`) et pièces jointes (`attach_file/3`)
  - Cas d'erreur (changeset invalide)
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Incidents, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Incidents.{Incident, IncidentComment, IncidentFile}
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

  defp setup_building_and_reporter do
    residence = insert_residence!()
    building = insert_building!(residence)
    reporter = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, reporter.id, :coproprietaire)
    {building, reporter}
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Fuite d'eau dans la cage d'escalier",
        "description" => "Trace d'humidité visible depuis ce matin.",
        "category" => "plomberie"
      },
      overrides
    )
  end

  describe "create_incident/3" do
    test "crée un incident standard avec les valeurs par défaut" do
      {building, reporter} = setup_building_and_reporter()

      assert {:ok, %Incident{} = incident} =
               Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert incident.title == "Fuite d'eau dans la cage d'escalier"
      assert incident.category == :plomberie
      assert incident.status == :open
      assert incident.severity == :medium
      assert incident.visibility == :standard
      assert incident.building_id == building.id
      assert incident.reporter_id == reporter.id
    end

    test "force building_id et reporter_id même s'ils sont dans attrs (verrou)" do
      {building, reporter} = setup_building_and_reporter()
      other = insert_user!()

      {:ok, incident} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{
            "building_id" => Ecto.UUID.generate(),
            "reporter_id" => other.id
          })
        )

      assert incident.building_id == building.id
      assert incident.reporter_id == reporter.id
    end

    test "crée un brouillon sans side-effect observable" do
      {building, reporter} = setup_building_and_reporter()

      {:ok, incident} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{"status" => "brouillon"})
        )

      assert incident.status == :brouillon
    end

    test "crée un incident council_only" do
      {building, reporter} = setup_building_and_reporter()

      {:ok, incident} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{"visibility" => "council_only"})
        )

      assert incident.visibility == :council_only
    end

    test "rejette un titre trop court" do
      {building, reporter} = setup_building_and_reporter()

      assert {:error, %Ecto.Changeset{} = cs} =
               Incidents.create_incident(
                 building.id,
                 reporter.id,
                 valid_attrs(%{"title" => "abc"})
               )

      assert "should be at least 5 character(s)" in errors_on(cs).title
    end

    test "rejette une description manquante" do
      {building, reporter} = setup_building_and_reporter()

      attrs = valid_attrs() |> Map.delete("description")

      assert {:error, %Ecto.Changeset{} = cs} =
               Incidents.create_incident(building.id, reporter.id, attrs)

      assert %{description: _} = errors_on(cs)
    end
  end

  describe "get_incident/1 & get_incident!/1" do
    test "get_incident/1 retourne l'incident ou nil" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert %Incident{id: id} = Incidents.get_incident(incident.id)
      assert id == incident.id
      assert is_nil(Incidents.get_incident(Ecto.UUID.generate()))
    end

    test "get_incident!/1 précharge les associations" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      loaded = Incidents.get_incident!(incident.id)
      assert loaded.reporter.id == reporter.id
      assert is_list(loaded.files)
      assert is_list(loaded.comments)
    end

    test "get_incident!/1 lève sur un id inconnu" do
      assert_raise Ecto.NoResultsError, fn ->
        Incidents.get_incident!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_incident/2" do
    test "met à jour le statut et la sévérité" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:ok, updated} =
               Incidents.update_incident(incident, %{
                 "status" => "in_progress",
                 "severity" => "high"
               })

      assert updated.status == :in_progress
      assert updated.severity == :high
    end

    test "rejette un statut invalide" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:error, %Ecto.Changeset{}} =
               Incidents.update_incident(incident, %{"status" => "not_a_status"})
    end
  end

  describe "resolve_incident/2" do
    test "passe l'incident à resolved avec note et horodatage" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:ok, resolved} =
               Incidents.resolve_incident(incident, "Plombier passé, fuite colmatée.")

      assert resolved.status == :resolved
      assert resolved.resolution_note == "Plombier passé, fuite colmatée."
      refute is_nil(resolved.resolved_at)
    end
  end

  describe "list_incidents/3 visibility" do
    test "cache les brouillons aux résidents lambda" do
      {building, reporter} = setup_building_and_reporter()

      {:ok, _draft} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{"status" => "brouillon"})
        )

      {:ok, open} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      ids = Incidents.list_incidents(building.id, %{}, reporter) |> Enum.map(& &1.id)

      assert open.id in ids
      assert length(ids) == 1
    end

    test "montre les brouillons aux privilégiés (président CS)" do
      {building, reporter} = setup_building_and_reporter()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

      {:ok, draft} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{"status" => "brouillon"})
        )

      ids = Incidents.list_incidents(building.id, %{}, president) |> Enum.map(& &1.id)
      assert draft.id in ids
    end

    test "cache les incidents council_only aux résidents lambda" do
      {building, reporter} = setup_building_and_reporter()

      {:ok, _confidential} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{"visibility" => "council_only"})
        )

      {:ok, standard} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      ids = Incidents.list_incidents(building.id, %{}, reporter) |> Enum.map(& &1.id)
      assert standard.id in ids
      assert length(ids) == 1
    end

    test "montre les incidents council_only aux privilégiés" do
      {building, reporter} = setup_building_and_reporter()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

      {:ok, confidential} =
        Incidents.create_incident(
          building.id,
          reporter.id,
          valid_attrs(%{"visibility" => "council_only"})
        )

      ids = Incidents.list_incidents(building.id, %{}, president) |> Enum.map(& &1.id)
      assert confidential.id in ids
    end

    test "filtre par status" do
      {building, reporter} = setup_building_and_reporter()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

      {:ok, open} = Incidents.create_incident(building.id, reporter.id, valid_attrs())
      {:ok, other} = Incidents.create_incident(building.id, reporter.id, valid_attrs())
      {:ok, _resolved} = Incidents.resolve_incident(other, "réglé")

      open_ids =
        Incidents.list_incidents(building.id, %{"status" => "open"}, president)
        |> Enum.map(& &1.id)

      assert open.id in open_ids
      refute other.id in open_ids
    end

    test "isole les incidents par bâtiment" do
      {building_a, reporter_a} = setup_building_and_reporter()
      {building_b, reporter_b} = setup_building_and_reporter()

      {:ok, inc_a} = Incidents.create_incident(building_a.id, reporter_a.id, valid_attrs())
      {:ok, _inc_b} = Incidents.create_incident(building_b.id, reporter_b.id, valid_attrs())

      ids = Incidents.list_incidents(building_a.id, %{}, reporter_a) |> Enum.map(& &1.id)
      assert inc_a.id in ids
      assert length(ids) == 1
    end
  end

  describe "privileged?/2" do
    test "true pour super_admin global peu importe le bâtiment" do
      residence = insert_residence!()
      building = insert_building!(residence)
      admin = insert_user!(:super_admin)
      assert Incidents.privileged?(building.id, admin)
    end

    test "true pour president_cs membre du bâtiment" do
      {building, _reporter} = setup_building_and_reporter()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)
      assert Incidents.privileged?(building.id, president)
    end

    test "false pour un copropriétaire standard" do
      {building, reporter} = setup_building_and_reporter()
      refute Incidents.privileged?(building.id, reporter)
    end

    test "false quand user est nil" do
      refute Incidents.privileged?(Ecto.UUID.generate(), nil)
    end
  end

  describe "AI answer flow" do
    setup do
      {building, reporter} = setup_building_and_reporter()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())
      %{incident: incident, president: president}
    end

    test "update_ai_answer/4 enregistre le texte proposé", %{incident: incident, president: p} do
      assert {:ok, updated} =
               Incidents.update_ai_answer(incident, "Voici une piste de réponse.", p.id)

      assert updated.ai_answer == "Voici une piste de réponse."
      refute is_nil(updated.ai_answered_at)
      assert is_nil(updated.ai_answer_confirmed_at)
    end

    test "update_ai_answer/4 avec confirm: true valide en un coup", %{
      incident: incident,
      president: p
    } do
      assert {:ok, updated} =
               Incidents.update_ai_answer(incident, "Réponse validée.", p.id, confirm: true)

      assert updated.ai_answer == "Réponse validée."
      refute is_nil(updated.ai_answer_confirmed_at)
      assert updated.ai_answer_confirmed_by_id == p.id
    end

    test "update_ai_answer/4 texte vide efface tout", %{incident: incident, president: p} do
      {:ok, with_answer} = Incidents.update_ai_answer(incident, "Un texte", p.id, confirm: true)

      assert {:ok, cleared} = Incidents.update_ai_answer(with_answer, "   ", p.id)
      assert is_nil(cleared.ai_answer)
      assert is_nil(cleared.ai_answered_at)
      assert is_nil(cleared.ai_answer_confirmed_at)
    end

    test "confirm_ai_answer/2 puis unconfirm_ai_answer/1", %{incident: incident, president: p} do
      {:ok, with_answer} = Incidents.update_ai_answer(incident, "Proposition", p.id)

      {:ok, confirmed} = Incidents.confirm_ai_answer(with_answer, p.id)
      refute is_nil(confirmed.ai_answer_confirmed_at)
      assert confirmed.ai_answer_confirmed_by_id == p.id

      {:ok, unconfirmed} = Incidents.unconfirm_ai_answer(confirmed)
      assert is_nil(unconfirmed.ai_answer_confirmed_at)
      assert is_nil(unconfirmed.ai_answer_confirmed_by_id)
    end
  end

  describe "add_comment/3" do
    test "ajoute un commentaire public" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:ok, %IncidentComment{} = comment} =
               Incidents.add_comment(incident.id, reporter.id, %{"body" => "Un voisin confirme."})

      assert comment.body == "Un voisin confirme."
      assert comment.incident_id == incident.id
      assert comment.author_id == reporter.id
      refute comment.is_internal
    end

    test "ajoute un commentaire interne (pas de notif)" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:ok, comment} =
               Incidents.add_comment(incident.id, reporter.id, %{
                 "body" => "Note syndic importée par email.",
                 "is_internal" => true
               })

      assert comment.is_internal
    end

    test "rejette un commentaire au corps vide" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:error, %Ecto.Changeset{}} =
               Incidents.add_comment(incident.id, reporter.id, %{"body" => ""})
    end
  end

  describe "files" do
    test "attach_file/3, get_file!/1 puis delete_file/1" do
      {building, reporter} = setup_building_and_reporter()
      {:ok, incident} = Incidents.create_incident(building.id, reporter.id, valid_attrs())

      assert {:ok, %IncidentFile{} = file} =
               Incidents.attach_file(incident.id, reporter, %{
                 "kind" => "photo",
                 "filename" => "photo.jpg",
                 "file_url" => "/uploads/photo.jpg",
                 "mime_type" => "image/jpeg",
                 "file_size_bytes" => 1024
               })

      assert file.incident_id == incident.id
      assert file.uploaded_by_id == reporter.id
      assert Incidents.get_file!(file.id).id == file.id

      assert {:ok, _} = Incidents.delete_file(file)
      assert is_nil(Repo.get(IncidentFile, file.id))
    end
  end
end
