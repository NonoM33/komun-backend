defmodule KomunBackend.EventsTest do
  @moduledoc """
  Smoke test du domaine Events. Couvre les chemins critiques :
    - création (avec scope bâtiments + sans scope résidence entière),
    - permissions (council peut créer, voisin lambda non),
    - RSVP avec plus_ones plafonné à 5,
    - contributions (template + libre + claim),
    - soft-cancel,
    - visibilité scope (un bâtiment hors scope ne voit rien).
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Events, Residences}
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

  defp insert_building!(residence, name \\ nil) do
    %Building{}
    |> Building.initial_changeset(%{
      name: name || "Bâtiment #{System.unique_integer([:positive])}",
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

  defp setup_residence_with_council do
    residence = insert_residence!()
    building_a = insert_building!(residence, "Bât A")
    building_b = insert_building!(residence, "Bât B")

    council = insert_user!()
    {:ok, _} = Buildings.add_member(building_a.id, council.id, :president_cs)

    voisin = insert_user!()
    {:ok, _} = Buildings.add_member(building_a.id, voisin.id, :coproprietaire)

    %{
      residence: residence,
      building_a: building_a,
      building_b: building_b,
      council: council,
      voisin: voisin
    }
  end

  defp future_dt(hours_from_now) do
    DateTime.utc_now()
    |> DateTime.add(hours_from_now * 3600, :second)
    |> DateTime.truncate(:second)
  end

  describe "permissions de création" do
    test "le conseil syndical peut créer un event" do
      ctx = setup_residence_with_council()

      assert Events.can_create_event?(ctx.residence.id, ctx.council)
    end

    test "un voisin lambda ne peut pas créer un event" do
      ctx = setup_residence_with_council()

      refute Events.can_create_event?(ctx.residence.id, ctx.voisin)
    end

    test "super_admin peut toujours créer" do
      residence = insert_residence!()
      admin = insert_user!(:super_admin)

      assert Events.can_create_event?(residence.id, admin)
    end
  end

  describe "create_event/3" do
    test "crée un event résidence (sans scope) et inscrit le créateur comme :creator" do
      ctx = setup_residence_with_council()

      attrs = %{
        "title" => "Fête des voisins",
        "description" => "Apéro convivial dans le jardin",
        "kind" => "festif",
        "status" => "published",
        "starts_at" => future_dt(48),
        "ends_at" => future_dt(52),
        "location_label" => "Jardin commun"
      }

      assert {:ok, event} = Events.create_event(ctx.residence.id, ctx.council, attrs)
      assert event.title == "Fête des voisins"
      assert event.residence_id == ctx.residence.id
      assert event.building_scopes == []

      assert [organizer] = event.organizers
      assert organizer.user_id == ctx.council.id
      assert organizer.role == :creator
    end

    test "crée un event scopé à Bât A uniquement" do
      ctx = setup_residence_with_council()

      attrs = %{
        "title" => "Apéro Bât A",
        "starts_at" => future_dt(72),
        "ends_at" => future_dt(76),
        "status" => "published",
        "building_ids" => [ctx.building_a.id]
      }

      assert {:ok, event} = Events.create_event(ctx.residence.id, ctx.council, attrs)
      assert [scope] = event.building_scopes
      assert scope.building_id == ctx.building_a.id
    end
  end

  describe "list_events_for_building/3" do
    test "Bât B ne voit pas un event scopé Bât A (invisible totalement)" do
      ctx = setup_residence_with_council()

      {:ok, _event_a} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Apéro Bât A privé",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published",
          "building_ids" => [ctx.building_a.id]
        })

      events_b = Events.list_events_for_building(ctx.building_b.id, %{}, ctx.voisin)
      assert events_b == []
    end

    test "Bât A voit l'event scopé Bât A + l'event résidence" do
      ctx = setup_residence_with_council()

      {:ok, _event_residence} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Fête de toute la résidence",
          "starts_at" => future_dt(48),
          "ends_at" => future_dt(52),
          "status" => "published"
        })

      {:ok, _event_scoped} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Apéro Bât A",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published",
          "building_ids" => [ctx.building_a.id]
        })

      events = Events.list_events_for_building(ctx.building_a.id, %{}, ctx.voisin)
      assert length(events) == 2
    end
  end

  describe "RSVP / participations" do
    test "upsert RSVP going + plus_ones acceptés jusqu'à 5" do
      ctx = setup_residence_with_council()

      {:ok, event} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Fête",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published"
        })

      assert {:ok, p} =
               Events.upsert_participation(event.id, ctx.voisin.id, %{
                 "status" => "going",
                 "plus_ones_count" => 3,
                 "dietary_note" => "végé + allergie arachide"
               })

      assert p.status == :going
      assert p.plus_ones_count == 3
      assert p.dietary_note == "végé + allergie arachide"
    end

    test "plus_ones > 5 rejeté" do
      ctx = setup_residence_with_council()

      {:ok, event} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Fête",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published"
        })

      assert {:error, cs} =
               Events.upsert_participation(event.id, ctx.voisin.id, %{
                 "status" => "going",
                 "plus_ones_count" => 6
               })

      assert %{plus_ones_count: _} = errors_on(cs)
    end
  end

  describe "contributions / claims" do
    test "create + claim + claimed_quantity reflète bien la somme" do
      ctx = setup_residence_with_council()

      {:ok, event} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Fête potluck",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published"
        })

      {:ok, contribution} =
        Events.create_contribution(event.id, ctx.council.id, %{
          "title" => "Salade composée",
          "category" => "entree",
          "needed_quantity" => 4
        })

      {:ok, _} =
        Events.add_claim(contribution.id, ctx.voisin.id, %{
          "quantity" => 2,
          "comment" => "salade niçoise"
        })

      reloaded = Events.get_event!(event.id)
      [c] = reloaded.contributions
      assert c.title == "Salade composée"
      assert length(c.claims) == 1
      assert hd(c.claims).quantity == 2
    end
  end

  describe "soft-cancel" do
    test "cancel_event/2 bascule status en :cancelled et set la raison" do
      ctx = setup_residence_with_council()

      {:ok, event} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Annulé pour cause de pluie",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published"
        })

      assert {:ok, cancelled} = Events.cancel_event(event, "Pluie battante annoncée")
      assert cancelled.status == :cancelled
      assert cancelled.cancelled_reason == "Pluie battante annoncée"
      refute is_nil(cancelled.cancelled_at)
    end
  end

  describe "commentaires + réactions" do
    test "add_comment + toggle_reaction emoji" do
      ctx = setup_residence_with_council()

      {:ok, event} =
        Events.create_event(ctx.residence.id, ctx.council, %{
          "title" => "Discussion",
          "starts_at" => future_dt(24),
          "ends_at" => future_dt(28),
          "status" => "published"
        })

      {:ok, comment} =
        Events.add_comment(event.id, ctx.voisin.id, %{"body" => "J'apporte la sono"})

      assert comment.body == "J'apporte la sono"

      {:ok, with_reaction} = Events.toggle_reaction(comment, "❤️", ctx.council.id)
      assert with_reaction.reactions["❤️"]["count"] == 1

      # Toggle à nouveau retire la réaction
      {:ok, no_reaction} = Events.toggle_reaction(with_reaction, "❤️", ctx.council.id)
      refute Map.has_key?(no_reaction.reactions, "❤️")
    end
  end
end
