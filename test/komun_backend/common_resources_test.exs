defmodule KomunBackend.CommonResourcesTest do
  @moduledoc """
  Tests du contexte CommonResources — ressources communes réservables
  et workflow de validation par le conseil syndical.

  Couvre les invariants critiques :
  - Création de ressource avec valeurs par défaut sensées
  - Validation du préavis (`advance_notice_hours`) à la création d'une
    réservation : pas de demande pour demain matin si la ressource exige
    48h
  - Validation de la fenêtre horaire et de la durée maximum
  - Anti-chevauchement sur ressource exclusive (pending + approved)
  - Workflow complet : pending → approved / rejected / cancelled
  - Authz : `admin?/2` et `can_validate?/2` aux bons rôles
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, CommonResources, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.CommonResources.{Resource, Booking}
  alias KomunBackend.Residences.Residence

  # ------------------------------------------------------------------
  # Fixtures (alignées sur diligences_test.exs)
  # ------------------------------------------------------------------

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

  defp setup_building do
    residence = insert_residence!()
    building = insert_building!(residence)
    {residence, building}
  end

  defp insert_resource!(building, attrs \\ %{}) do
    base = %{
      "name" => "Ascenseur",
      "kind" => "elevator",
      "advance_notice_hours" => 48,
      "max_duration_hours" => 8,
      "allowed_hours_start" => 8,
      "allowed_hours_end" => 20,
      "exclusive" => true,
      "active" => true
    }

    {:ok, r} = CommonResources.create_resource(building.id, Map.merge(base, attrs))
    r
  end

  # Renvoie un DateTime ISO8601 dans `hours_ahead` heures, à `hour_of_day`
  # heure UTC. La TZ "Europe/Paris" n'est pas chargée en test (pas de
  # tzdata configuré), et la prod tombe aussi sur UTC — donc le contexte
  # interprète `allowed_hours_*` comme des heures UTC, ce qui est cohérent.
  defp future_dt_iso(hours_ahead, hour_of_day) do
    today = Date.utc_today() |> Date.add(div(hours_ahead, 24) + 1)
    {:ok, dt} = DateTime.new(today, ~T[00:00:00], "Etc/UTC")

    %{dt | hour: hour_of_day, minute: 0, second: 0}
    |> DateTime.to_iso8601()
  end

  # ------------------------------------------------------------------
  # Resources CRUD
  # ------------------------------------------------------------------

  describe "create_resource/2" do
    test "crée une ressource avec les valeurs fournies" do
      {_, building} = setup_building()

      {:ok, %Resource{} = r} =
        CommonResources.create_resource(building.id, %{
          "name" => "Ascenseur",
          "kind" => "elevator",
          "advance_notice_hours" => 48
        })

      assert r.building_id == building.id
      assert r.name == "Ascenseur"
      assert r.kind == :elevator
      assert r.advance_notice_hours == 48
      assert r.exclusive == true
      assert r.active == true
    end

    test "rejette un name trop court" do
      {_, building} = setup_building()

      {:error, cs} =
        CommonResources.create_resource(building.id, %{
          "name" => "X",
          "kind" => "elevator"
        })

      assert %{name: _} = errors_on(cs)
    end

    test "rejette une fenêtre horaire incohérente (end <= start)" do
      {_, building} = setup_building()

      {:error, cs} =
        CommonResources.create_resource(building.id, %{
          "name" => "Salle commune",
          "kind" => "common_room",
          "allowed_hours_start" => 20,
          "allowed_hours_end" => 8
        })

      assert %{allowed_hours_end: _} = errors_on(cs)
    end
  end

  describe "list_resources/1" do
    test "ne renvoie que les ressources actives" do
      {_, building} = setup_building()
      _active = insert_resource!(building)
      _inactive = insert_resource!(building, %{"name" => "Vélos", "active" => false})

      assert [r] = CommonResources.list_resources(building.id)
      assert r.name == "Ascenseur"
    end

    test "list_all_resources/1 renvoie tout (admin)" do
      {_, building} = setup_building()
      _active = insert_resource!(building)
      _inactive = insert_resource!(building, %{"name" => "Vélos", "active" => false})

      assert length(CommonResources.list_all_resources(building.id)) == 2
    end
  end

  # ------------------------------------------------------------------
  # Bookings
  # ------------------------------------------------------------------

  describe "create_booking/3 — préavis" do
    test "rejette une demande qui ne respecte pas le préavis 48h" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 48})
      user = insert_user!()

      # Demande pour dans 12h : préavis violé (besoin 48h).
      attrs = %{
        "starts_at" => future_dt_iso(12, 10),
        "ends_at" => future_dt_iso(12, 12),
        "reason" => "Déménagement"
      }

      assert {:error, :advance_notice_not_met} =
               CommonResources.create_booking(resource.id, user.id, attrs)
    end

    test "accepte une demande qui respecte le préavis" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 48})
      user = insert_user!()

      attrs = %{
        "starts_at" => future_dt_iso(60, 10),
        "ends_at" => future_dt_iso(60, 14),
        "reason" => "Déménagement"
      }

      {:ok, %Booking{} = b} =
        CommonResources.create_booking(resource.id, user.id, attrs)

      assert b.status == :pending
      assert b.requester_id == user.id
      assert b.common_resource_id == resource.id
    end
  end

  describe "create_booking/3 — fenêtre horaire" do
    test "rejette en dehors des heures autorisées (allowed_hours_*)" do
      {_, building} = setup_building()

      resource =
        insert_resource!(building, %{
          "advance_notice_hours" => 0,
          "allowed_hours_start" => 8,
          "allowed_hours_end" => 20
        })

      user = insert_user!()

      # Demande à 22h (hors fenêtre 8h-20h).
      attrs = %{
        "starts_at" => future_dt_iso(2, 22),
        "ends_at" => future_dt_iso(2, 23),
        "reason" => "..."
      }

      assert {:error, :outside_allowed_hours} =
               CommonResources.create_booking(resource.id, user.id, attrs)
    end
  end

  describe "create_booking/3 — durée max" do
    test "rejette si la durée excède max_duration_hours" do
      {_, building} = setup_building()

      resource =
        insert_resource!(building, %{
          "advance_notice_hours" => 0,
          "max_duration_hours" => 4
        })

      user = insert_user!()

      attrs = %{
        "starts_at" => future_dt_iso(2, 8),
        "ends_at" => future_dt_iso(2, 14),
        "reason" => "..."
      }

      assert {:error, :duration_exceeded} =
               CommonResources.create_booking(resource.id, user.id, attrs)
    end
  end

  describe "create_booking/3 — chevauchement (exclusive)" do
    test "rejette une demande qui chevauche une réservation pending" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      u1 = insert_user!()
      u2 = insert_user!()

      attrs1 = %{
        "starts_at" => future_dt_iso(2, 9),
        "ends_at" => future_dt_iso(2, 13),
        "reason" => "Premier"
      }

      {:ok, _} = CommonResources.create_booking(resource.id, u1.id, attrs1)

      # Chevauche partiellement (10h-12h vs 9h-13h)
      attrs2 = %{
        "starts_at" => future_dt_iso(2, 10),
        "ends_at" => future_dt_iso(2, 12),
        "reason" => "Second"
      }

      assert {:error, :overlap} =
               CommonResources.create_booking(resource.id, u2.id, attrs2)
    end

    test "accepte deux demandes consécutives sans chevauchement" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      u1 = insert_user!()
      u2 = insert_user!()

      attrs1 = %{
        "starts_at" => future_dt_iso(2, 9),
        "ends_at" => future_dt_iso(2, 11),
        "reason" => "Premier"
      }

      attrs2 = %{
        "starts_at" => future_dt_iso(2, 11),
        "ends_at" => future_dt_iso(2, 13),
        "reason" => "Second"
      }

      {:ok, _} = CommonResources.create_booking(resource.id, u1.id, attrs1)
      {:ok, _} = CommonResources.create_booking(resource.id, u2.id, attrs2)
    end

    test "rejette une demande sur ressource inactive" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"active" => false})
      user = insert_user!()

      attrs = %{
        "starts_at" => future_dt_iso(60, 10),
        "ends_at" => future_dt_iso(60, 12),
        "reason" => "..."
      }

      assert {:error, :resource_inactive} =
               CommonResources.create_booking(resource.id, user.id, attrs)
    end
  end

  describe "approve_booking/2" do
    test "passe pending → approved avec horodatage et auteur" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      user = insert_user!()
      validator = insert_user!(:president_cs)

      {:ok, booking} =
        CommonResources.create_booking(resource.id, user.id, %{
          "starts_at" => future_dt_iso(2, 9),
          "ends_at" => future_dt_iso(2, 11),
          "reason" => "Déménagement"
        })

      {:ok, approved} = CommonResources.approve_booking(booking, validator.id)

      assert approved.status == :approved
      assert approved.validated_by_id == validator.id
      assert approved.validated_at
    end

    test "refuse une approbation sur un booking déjà approuvé" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      user = insert_user!()
      validator = insert_user!()

      {:ok, booking} =
        CommonResources.create_booking(resource.id, user.id, %{
          "starts_at" => future_dt_iso(2, 9),
          "ends_at" => future_dt_iso(2, 11),
          "reason" => "..."
        })

      {:ok, approved} = CommonResources.approve_booking(booking, validator.id)
      assert {:error, :not_pending} = CommonResources.approve_booking(approved, validator.id)
    end
  end

  describe "reject_booking/3" do
    test "passe pending → rejected avec motif optionnel" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      user = insert_user!()
      validator = insert_user!()

      {:ok, booking} =
        CommonResources.create_booking(resource.id, user.id, %{
          "starts_at" => future_dt_iso(2, 9),
          "ends_at" => future_dt_iso(2, 11),
          "reason" => "..."
        })

      {:ok, rejected} =
        CommonResources.reject_booking(booking, validator.id, "Conflit avec AG")

      assert rejected.status == :rejected
      assert rejected.rejection_reason == "Conflit avec AG"
      assert rejected.validated_by_id == validator.id
    end
  end

  describe "cancel_booking/1" do
    test "annule une demande pending" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      user = insert_user!()

      {:ok, booking} =
        CommonResources.create_booking(resource.id, user.id, %{
          "starts_at" => future_dt_iso(2, 9),
          "ends_at" => future_dt_iso(2, 11),
          "reason" => "..."
        })

      {:ok, cancelled} = CommonResources.cancel_booking(booking)
      assert cancelled.status == :cancelled
    end

    test "idempotent sur déjà annulé / rejeté" do
      {_, building} = setup_building()
      resource = insert_resource!(building, %{"advance_notice_hours" => 0})
      user = insert_user!()
      validator = insert_user!()

      {:ok, booking} =
        CommonResources.create_booking(resource.id, user.id, %{
          "starts_at" => future_dt_iso(2, 9),
          "ends_at" => future_dt_iso(2, 11),
          "reason" => "..."
        })

      {:ok, _} = CommonResources.reject_booking(booking, validator.id)
      reloaded = CommonResources.get_booking!(booking.id)
      {:ok, b} = CommonResources.cancel_booking(reloaded)
      assert b.status == :rejected
    end
  end

  # ------------------------------------------------------------------
  # Authz helpers
  # ------------------------------------------------------------------

  describe "admin?/2" do
    test "vrai pour super_admin et syndic_manager, faux pour coproprietaire" do
      {_, building} = setup_building()
      assert CommonResources.admin?(building.id, %User{role: :super_admin})
      assert CommonResources.admin?(building.id, %User{role: :syndic_manager})
      assert CommonResources.admin?(building.id, %User{role: :syndic_staff})
      refute CommonResources.admin?(building.id, %User{role: :coproprietaire})
      refute CommonResources.admin?(building.id, %User{role: :president_cs})
      refute CommonResources.admin?(building.id, nil)
    end
  end

  describe "can_validate?/2" do
    test "vrai pour super_admin / syndic / membre conseil syndical du bâtiment" do
      {_, building} = setup_building()

      copro = insert_user!(:coproprietaire)
      pres = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, pres.id, :president_cs)

      assert CommonResources.can_validate?(building.id, %User{role: :super_admin})
      assert CommonResources.can_validate?(building.id, %User{role: :syndic_manager})
      assert CommonResources.can_validate?(building.id, pres)
      refute CommonResources.can_validate?(building.id, copro)
    end
  end

  describe "list_validators_for_building/1" do
    test "renvoie les membres CS actifs + syndic globaux" do
      {_, building} = setup_building()

      pres = insert_user!(:coproprietaire)
      membre = insert_user!(:coproprietaire)
      copro = insert_user!(:coproprietaire)
      syndic = insert_user!(:syndic_manager)

      {:ok, _} = Buildings.add_member(building.id, pres.id, :president_cs)
      {:ok, _} = Buildings.add_member(building.id, membre.id, :membre_cs)
      {:ok, _} = Buildings.add_member(building.id, copro.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, syndic.id, :coproprietaire)

      ids = CommonResources.list_validators_for_building(building.id) |> Enum.map(& &1.id)

      assert pres.id in ids
      assert membre.id in ids
      assert syndic.id in ids
      refute copro.id in ids
    end
  end
end
