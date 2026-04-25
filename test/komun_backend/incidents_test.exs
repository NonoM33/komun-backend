defmodule KomunBackend.IncidentsTest do
  @moduledoc """
  Tests de non-divulgation pour le contexte Incidents.

  La règle métier : un signalement `:council_only` n'est visible que par
  le syndic, le conseil syndical, les super_admin… **et son auteur lui-même**
  (sinon le créateur perd la main sur sa propre data après envoi).

  Cette suite gèle les invariants de visibilité au niveau du contexte —
  les tests controller (sérialisation JSON, endpoints) sont à part dans
  `incident_controller_test.exs`.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Incidents, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Incidents.Incident
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

  defp insert_incident!(building, reporter, attrs \\ %{}) do
    defaults = %{
      title: "Fuite dans le local poubelles",
      description: "De l'eau coule du plafond depuis ce matin.",
      category: :plomberie,
      severity: :medium,
      visibility: :standard,
      building_id: building.id,
      reporter_id: reporter.id
    }

    %Incident{}
    |> Incident.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp setup_building_with_member!(role) do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, role)
    {building, user}
  end

  describe "privileged?/2" do
    test "true pour un super_admin (rôle global)" do
      {building, _} = setup_building_with_member!(:coproprietaire)
      admin = insert_user!(:super_admin)

      assert Incidents.privileged?(building.id, admin)
    end

    test "true pour un syndic_manager (rôle global)" do
      {building, _} = setup_building_with_member!(:coproprietaire)
      syndic = insert_user!(:syndic_manager)

      assert Incidents.privileged?(building.id, syndic)
    end

    test "true pour un syndic_staff (rôle global)" do
      {building, _} = setup_building_with_member!(:coproprietaire)
      staff = insert_user!(:syndic_staff)

      assert Incidents.privileged?(building.id, staff)
    end

    test "true pour un BuildingMember :president_cs du bâtiment" do
      {building, president} = setup_building_with_member!(:president_cs)
      assert Incidents.privileged?(building.id, president)
    end

    test "true pour un BuildingMember :membre_cs du bâtiment" do
      {building, member} = setup_building_with_member!(:membre_cs)
      assert Incidents.privileged?(building.id, member)
    end

    test "false pour un :coproprietaire simple" do
      {building, user} = setup_building_with_member!(:coproprietaire)
      refute Incidents.privileged?(building.id, user)
    end

    test "false pour un :locataire" do
      {building, user} = setup_building_with_member!(:locataire)
      refute Incidents.privileged?(building.id, user)
    end

    test "false pour un :gardien" do
      {building, user} = setup_building_with_member!(:gardien)
      refute Incidents.privileged?(building.id, user)
    end

    test "false pour nil (utilisateur non authentifié)" do
      {building, _} = setup_building_with_member!(:coproprietaire)
      refute Incidents.privileged?(building.id, nil)
    end

    test "false pour un :membre_cs d'un AUTRE bâtiment" do
      {building_a, _} = setup_building_with_member!(:coproprietaire)
      # User est :membre_cs dans le bâtiment B, mais on demande pour A
      {_building_b, member_of_b} = setup_building_with_member!(:membre_cs)

      refute Incidents.privileged?(building_a.id, member_of_b)
    end
  end

  describe "list_incidents/3 — visibilité :council_only" do
    setup do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, reporter.id, :coproprietaire)

      bystander = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, bystander.id, :coproprietaire)

      cs_member = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, cs_member.id, :membre_cs)

      admin = insert_user!(:super_admin)

      standard = insert_incident!(building, reporter, %{visibility: :standard, title: "Standard incident"})
      confidential = insert_incident!(building, reporter, %{visibility: :council_only, title: "Confidentiel"})

      {:ok,
       building: building,
       reporter: reporter,
       bystander: bystander,
       cs_member: cs_member,
       admin: admin,
       standard: standard,
       confidential: confidential}
    end

    test "cache un :council_only à un coproprio tiers", ctx do
      ids =
        ctx.building.id
        |> Incidents.list_incidents(%{}, ctx.bystander)
        |> Enum.map(& &1.id)

      assert ctx.standard.id in ids
      refute ctx.confidential.id in ids
    end

    test "montre un :council_only à son propre créateur (même non-privilégié)", ctx do
      ids =
        ctx.building.id
        |> Incidents.list_incidents(%{}, ctx.reporter)
        |> Enum.map(& &1.id)

      assert ctx.standard.id in ids
      assert ctx.confidential.id in ids,
             "Le créateur doit voir son propre signalement confidentiel — sinon il perd la main sur sa data."
    end

    test "montre un :council_only à un :membre_cs du bâtiment", ctx do
      ids =
        ctx.building.id
        |> Incidents.list_incidents(%{}, ctx.cs_member)
        |> Enum.map(& &1.id)

      assert ctx.standard.id in ids
      assert ctx.confidential.id in ids
    end

    test "montre un :council_only à un :super_admin", ctx do
      ids =
        ctx.building.id
        |> Incidents.list_incidents(%{}, ctx.admin)
        |> Enum.map(& &1.id)

      assert ctx.standard.id in ids
      assert ctx.confidential.id in ids
    end

    test "retourne les :standard à tout le monde (y compris non-membre via viewer nil)", ctx do
      ids =
        ctx.building.id
        |> Incidents.list_incidents(%{}, nil)
        |> Enum.map(& &1.id)

      # nil voit le standard mais PAS le confidentiel
      assert ctx.standard.id in ids
      refute ctx.confidential.id in ids
    end

    test "isolation par bâtiment : un :council_only de A n'apparaît pas dans B même pour son auteur", ctx do
      # Le reporter signale aussi un :council_only dans un AUTRE bâtiment
      other_residence = insert_residence!()
      other_building = insert_building!(other_residence)
      {:ok, _} = Buildings.add_member(other_building.id, ctx.reporter.id, :coproprietaire)

      other_confidential =
        insert_incident!(other_building, ctx.reporter, %{visibility: :council_only, title: "Autre bât."})

      ids_in_a =
        ctx.building.id
        |> Incidents.list_incidents(%{}, ctx.reporter)
        |> Enum.map(& &1.id)

      refute other_confidential.id in ids_in_a,
             "La visibilité auteur reste scoped au bâtiment — le filtre WHERE sur building_id n'est pas court-circuité."
    end
  end

  describe "create_incident/3 avec :council_only" do
    test "crée un incident avec visibility=:council_only et le bon reporter_id" do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      {:ok, incident} =
        Incidents.create_incident(building.id, user.id, %{
          "title" => "Tensions de voisinage",
          "description" => "Bruits récurrents la nuit, je préfère ne pas être identifié.",
          "category" => "autre",
          "visibility" => "council_only"
        })

      assert incident.visibility == :council_only
      assert incident.reporter_id == user.id
      assert incident.building_id == building.id
      # `ai_answer` doit rester nil — le triage IA est sauté pour les
      # contenus sensibles (voir le commentaire de bloc dans
      # KomunBackend.Incidents.create_incident/3).
      assert is_nil(incident.ai_answer)
    end
  end
end
