defmodule KomunBackend.Notifications.Jobs.NotifyUnitBelowJobTest do
  @moduledoc """
  Vérifie que le job NotifyUnitBelowJob trouve bien le voisin du dessous
  via Adjacency, lui envoie un email + un push, et reste silencieux dans
  les cas dégradés (pas de logement parent, pas de voisin du dessous,
  reporter sans primary_lot, etc.).

  Oban est en mode `:inline` côté test : enqueue = exécution immédiate.
  """

  use KomunBackend.DataCase, async: false
  use Oban.Testing, repo: KomunBackend.Repo
  import Swoosh.TestAssertions

  alias KomunBackend.{Buildings, Residences, Repo}
  alias KomunBackend.Buildings.{Building, Lot}
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Accounts.User
  alias KomunBackend.Incidents
  alias KomunBackend.Notifications.Jobs.NotifyUnitBelowJob

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

  defp insert_user!(email \\ nil) do
    e = email || "u#{System.unique_integer([:positive])}@test.local"

    %User{}
    |> User.changeset(%{email: e, role: :coproprietaire, push_tokens: ["fcm-#{e}"]})
    |> Repo.insert!()
  end

  defp link_member_to_lot!(building_id, user, lot) do
    {:ok, m} = Buildings.add_member(building_id, user.id, :coproprietaire)
    m |> Ecto.Changeset.change(primary_lot_id: lot.id) |> Repo.update!()
  end

  defp create_incident_for(building, reporter, attrs \\ %{}) do
    {:ok, inc} =
      Incidents.create_incident(building.id, reporter.id, %{
        "title" => attrs[:title] || "Fuite au plafond cuisine",
        "description" => "L'eau coule depuis ce matin",
        "category" => "plomberie",
        "subtype" => "water_leak"
      })

    inc
  end

  describe "perform/1 — chemin nominal" do
    test "envoie un email au membre du logement directement en dessous" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      reporter = insert_user!()
      neighbor = insert_user!("voisin@test.local")

      link_member_to_lot!(b.id, reporter, lot_2003)
      link_member_to_lot!(b.id, neighbor, lot_1003)

      incident = create_incident_for(b, reporter)

      # On rejoue le job explicitement pour vérifier qu'il fait bien le
      # travail attendu (en plus du déclenchement par create_incident).
      assert :ok = perform_job(NotifyUnitBelowJob, %{"incident_id" => incident.id})

      assert_email_sent(fn email ->
        assert {_, "voisin@test.local"} = hd(email.to)
        assert email.subject =~ "Dégât des eaux"
        assert email.subject =~ "2003"
        assert email.html_body =~ "1003"
        assert email.text_body =~ "vérifier rapidement"
      end)
    end

    test "respecte un override unit_below_lot_id manuel" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      _lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})
      lot_1002 = insert_lot!(b, %{number: "1002", floor: 1})

      # Override : 2003 est en dessus de 1002, pas 1003.
      lot_2003
      |> Lot.adjacency_changeset(%{unit_below_lot_id: lot_1002.id})
      |> Repo.update!()

      reporter = insert_user!()
      target = insert_user!("override@test.local")
      ignored = insert_user!("ignored@test.local")

      link_member_to_lot!(b.id, reporter, lot_2003)
      link_member_to_lot!(b.id, target, lot_1002)
      link_member_to_lot!(b.id, ignored, Repo.get_by(Lot, number: "1003", building_id: b.id))

      incident = create_incident_for(b, reporter)
      assert :ok = perform_job(NotifyUnitBelowJob, %{"incident_id" => incident.id})

      assert_email_sent(fn email ->
        assert {_, addr} = hd(email.to)
        assert addr == "override@test.local"
      end)
    end
  end

  describe "perform/1 — cas dégradés (no-op silencieux)" do
    test "no-op si le reporter n'a pas de primary_lot" do
      r = insert_residence!()
      b = insert_building!(r)

      _lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      reporter = insert_user!()
      neighbor = insert_user!("voisin@test.local")

      # Membre sans primary_lot
      {:ok, _} = Buildings.add_member(b.id, reporter.id, :coproprietaire)
      link_member_to_lot!(b.id, neighbor, lot_1003)

      incident = create_incident_for(b, reporter)
      assert :ok = perform_job(NotifyUnitBelowJob, %{"incident_id" => incident.id})

      assert_no_email_sent()
    end

    test "no-op si pas de logement en dessous" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      reporter = insert_user!()
      link_member_to_lot!(b.id, reporter, lot_1003)

      incident = create_incident_for(b, reporter)
      assert :ok = perform_job(NotifyUnitBelowJob, %{"incident_id" => incident.id})
      assert_no_email_sent()
    end

    test "no-op si l'incident n'existe plus" do
      assert :ok = perform_job(NotifyUnitBelowJob, %{"incident_id" => Ecto.UUID.generate()})
      assert_no_email_sent()
    end
  end

  describe "intégration avec Incidents.create_incident/2" do
    test "enqueue le job uniquement si subtype == water_leak" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      reporter = insert_user!()
      neighbor = insert_user!("voisin@test.local")
      link_member_to_lot!(b.id, reporter, lot_2003)
      link_member_to_lot!(b.id, neighbor, lot_1003)

      # Sans subtype → pas de notif voisin
      {:ok, _} =
        Incidents.create_incident(b.id, reporter.id, %{
          "title" => "Ascenseur en panne",
          "description" => "Bloqué au 2e",
          "category" => "ascenseur"
        })

      assert_no_email_sent()

      # Avec subtype water_leak → notif voisin
      {:ok, _} =
        Incidents.create_incident(b.id, reporter.id, %{
          "title" => "Fuite",
          "description" => "Plafond mouillé",
          "category" => "plomberie",
          "subtype" => "water_leak"
        })

      assert_email_sent(fn email ->
        assert {_, "voisin@test.local"} = hd(email.to)
      end)
    end

    test "n'enqueue PAS le job pour un incident :council_only" do
      r = insert_residence!()
      b = insert_building!(r)

      lot_2003 = insert_lot!(b, %{number: "2003", floor: 2})
      lot_1003 = insert_lot!(b, %{number: "1003", floor: 1})

      reporter = insert_user!()
      neighbor = insert_user!("voisin@test.local")
      link_member_to_lot!(b.id, reporter, lot_2003)
      link_member_to_lot!(b.id, neighbor, lot_1003)

      {:ok, _} =
        Incidents.create_incident(b.id, reporter.id, %{
          "title" => "Fuite",
          "description" => "Plafond mouillé",
          "category" => "plomberie",
          "subtype" => "water_leak",
          "visibility" => "council_only"
        })

      assert_no_email_sent()
    end
  end
end
