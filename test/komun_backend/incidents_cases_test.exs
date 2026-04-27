defmodule KomunBackend.IncidentsCasesTest do
  @moduledoc """
  Suivi des dossiers en cours auprès du syndic — couvre :
    - `add_follow_up/3` (permissions, refus si dossier clos, side-effects),
    - `list_open_cases/2` (filtre statut + visibilité, metrics, ordre),
    - `record_event/4` (alimenté par les use cases existants),
    - `link_doleance/3` / `unlink_doleance/2` (privileged-only),
    - `maybe_enqueue_follow_up_email` (debounce 24h).

  Aligné sur `BuildingsMembersTest` pour les fixtures.
  """

  use KomunBackend.DataCase, async: false

  import Swoosh.TestAssertions

  alias KomunBackend.{Buildings, Incidents, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Doleances.Doleance
  alias KomunBackend.Incidents.{Incident, IncidentEvent}
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

  defp insert_user!(role \\ :coproprietaire, attrs \\ %{}) do
    %User{}
    |> User.changeset(
      Map.merge(
        %{
          email: "user#{System.unique_integer([:positive])}@test.local",
          role: role
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_member!(building, user, role) do
    {:ok, m} = Buildings.add_member(building.id, user.id, role)
    m
  end

  defp insert_incident!(building, reporter, attrs \\ %{}) do
    base = %{
      "title" => "Porte d'entrée HS #{System.unique_integer([:positive])}",
      "description" => "Le pêne ne rentre plus, la porte ne ferme pas la nuit.",
      "category" => "serrurerie"
    }

    {:ok, i} = Incidents.create_incident(building.id, reporter.id, Map.merge(base, attrs))
    i
  end

  describe "add_follow_up/3 — permissions & validations" do
    test "un membre du conseil syndical peut relancer et alimente la timeline" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      cs_member = insert_user!()
      insert_member!(building, cs_member, :membre_cs)

      incident = insert_incident!(building, reporter)

      assert {:ok, %{incident: updated, event: event, comment: comment}} =
               Incidents.add_follow_up(incident, cs_member, "Toujours rien après 2 semaines.")

      assert updated.follow_up_count == 1
      assert updated.last_follow_up_at != nil
      assert updated.last_action_at != nil

      assert event.event_type == :follow_up
      assert event.actor_id == cs_member.id
      assert event.payload["message"] =~ "2 semaines"
      assert event.payload["comment_id"] == to_string(comment.id)

      assert comment.is_internal == false
      assert comment.body =~ "2 semaines"
    end

    test "un coproprietaire simple ne peut PAS relancer" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      voisin = insert_user!()
      insert_member!(building, voisin, :coproprietaire)

      incident = insert_incident!(building, reporter)

      assert {:error, :forbidden} =
               Incidents.add_follow_up(incident, voisin, "Quand est-ce qu'on règle ?")

      reloaded = Repo.get!(Incident, incident.id)
      assert reloaded.follow_up_count == 0
      assert is_nil(reloaded.last_follow_up_at)

      # Aucun event :follow_up ne doit avoir été créé.
      assert Repo.aggregate(
               from(e in IncidentEvent,
                 where: e.incident_id == ^incident.id and e.event_type == :follow_up
               ),
               :count,
               :id
             ) == 0
    end

    test "refuse de relancer un incident résolu / clos / rejeté" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      cs_member = insert_user!()
      insert_member!(building, cs_member, :membre_cs)

      for status <- [:resolved, :closed, :rejected] do
        incident = insert_incident!(building, reporter)

        {:ok, _} =
          incident
          |> Incident.changeset(%{status: status})
          |> Repo.update()

        incident = Repo.get!(Incident, incident.id)

        assert {:error, :incident_closed} =
                 Incidents.add_follow_up(incident, cs_member, "tentative tardive")
      end
    end
  end

  describe "add_follow_up/3 — debounce email" do
    test "envoie un email la première fois, skip la seconde dans la même tranche 24h" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      cs_member = insert_user!()
      insert_member!(building, cs_member, :membre_cs)

      syndic = insert_user!(:syndic_manager)
      insert_member!(building, syndic, :coproprietaire)

      incident = insert_incident!(building, reporter)

      assert {:ok, _} = Incidents.add_follow_up(incident, cs_member, "Premier rappel")
      assert_email_sent(subject: ~r/Relance dossier/)

      reloaded = Repo.get!(Incident, incident.id)
      assert {:ok, _} = Incidents.add_follow_up(reloaded, cs_member, "Deuxième rappel le même jour")

      # Deuxième relance dans la fenêtre 24h → pas d'email envoyé.
      # `assert_email_sent` ci-dessus a consommé le seul message en
      # mailbox ; si la 2e relance générait un email, il y serait
      # maintenant. `refute_email_sent/0` (sans filtre) garantit que
      # personne n'a été contacté.
      refute_email_sent()
    end
  end

  describe "list_open_cases/2" do
    test "ne renvoie que les dossiers :open / :in_progress, masque :council_only pour non-privilégié" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      cs_member = insert_user!()
      insert_member!(building, cs_member, :membre_cs)

      open_inc = insert_incident!(building, reporter)
      _resolved_inc = insert_incident!(building, reporter) |> close_status!(:resolved)
      _closed_inc = insert_incident!(building, reporter) |> close_status!(:closed)
      council_inc = insert_incident!(building, reporter, %{"visibility" => "council_only"})

      cases_for_resident = Incidents.list_open_cases(building.id, reporter)
      cases_for_cs = Incidents.list_open_cases(building.id, cs_member)

      assert Enum.map(cases_for_resident, & &1.id) == [open_inc.id]
      assert Enum.sort(Enum.map(cases_for_cs, & &1.id)) == Enum.sort([open_inc.id, council_inc.id])
    end

    test "calcule les metrics et trie par last_action_at ASC NULLS FIRST" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      old_inc = insert_incident!(building, reporter)
      recent_inc = insert_incident!(building, reporter)

      # On simule un dossier vraiment vieux en remontant inserted_at +
      # last_action_at de 20 jours.
      twenty_days_ago = DateTime.utc_now() |> DateTime.add(-20 * 86_400, :second) |> DateTime.truncate(:second)

      old_inc
      |> Incident.changeset(%{last_action_at: twenty_days_ago})
      |> Repo.update!()

      Repo.update_all(
        from(i in Incident, where: i.id == ^old_inc.id),
        set: [inserted_at: twenty_days_ago]
      )

      cases = Incidents.list_open_cases(building.id, reporter)

      [first, second] = cases
      assert first.id == old_inc.id
      assert second.id == recent_inc.id
      assert first.metrics.days_open >= 20
      assert first.metrics.days_since_last_action >= 20
      assert second.metrics.days_open == 0
    end
  end

  describe "list_events/2" do
    test "renvoie la timeline triée et inclut le :created auto" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      incident = insert_incident!(building, reporter)

      assert {:ok, [created_event | _rest]} = Incidents.list_events(incident.id, reporter)
      assert created_event.event_type == :created
      assert created_event.actor_id == reporter.id
    end

    test "renvoie :not_found pour un viewer non privilégié sur un :council_only" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      voisin = insert_user!()
      insert_member!(building, voisin, :coproprietaire)

      incident = insert_incident!(building, reporter, %{"visibility" => "council_only"})
      assert {:error, :not_found} = Incidents.list_events(incident.id, voisin)
    end
  end

  describe "record_event hooks dans les use cases existants" do
    test "update_incident enregistre :status_change quand le status évolue" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      incident = insert_incident!(building, reporter)
      {:ok, _updated} = Incidents.update_incident(incident, %{"status" => "in_progress"})

      events =
        Repo.all(
          from(e in IncidentEvent,
            where: e.incident_id == ^incident.id and e.event_type == :status_change
          )
        )

      assert length(events) == 1
      assert hd(events).payload == %{"from" => "open", "to" => "in_progress"}
    end

    test "add_comment enregistre :syndic_action si l'auteur est privilégié, :comment_added sinon" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      syndic = insert_user!(:syndic_manager)
      insert_member!(building, syndic, :coproprietaire)

      incident = insert_incident!(building, reporter)

      {:ok, _} = Incidents.add_comment(incident.id, reporter.id, %{"body" => "encore en panne"})
      {:ok, _} = Incidents.add_comment(incident.id, syndic.id, %{"body" => "intervention demain"})

      events =
        Repo.all(
          from(e in IncidentEvent,
            where: e.incident_id == ^incident.id,
            order_by: [asc: e.inserted_at]
          )
        )

      types = Enum.map(events, & &1.event_type)
      assert :comment_added in types
      assert :syndic_action in types
    end
  end

  describe "link_doleance/3 et unlink_doleance/2" do
    test "le syndic peut lier puis délier une doléance ; trace dans la timeline" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      syndic = insert_user!(:syndic_manager)
      insert_member!(building, syndic, :coproprietaire)

      incident = insert_incident!(building, reporter)

      {:ok, doleance} =
        %Doleance{}
        |> Doleance.changeset(%{
          "title" => "Plainte collective porte d'entrée",
          "description" => "Plusieurs incidents convergents.",
          "building_id" => building.id,
          "author_id" => reporter.id
        })
        |> Repo.insert()

      assert {:ok, linked} = Incidents.link_doleance(incident, doleance.id, syndic)
      assert linked.linked_doleance_id == doleance.id

      assert {:ok, unlinked} = Incidents.unlink_doleance(linked, syndic)
      assert is_nil(unlinked.linked_doleance_id)

      types =
        Repo.all(
          from(e in IncidentEvent,
            where: e.incident_id == ^incident.id and e.event_type in [:linked_doleance, :unlinked_doleance],
            order_by: [asc: e.inserted_at],
            select: e.event_type
          )
        )

      assert types == [:linked_doleance, :unlinked_doleance]
    end

    test "un coproprietaire simple ne peut pas lier" do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      incident = insert_incident!(building, reporter)

      {:ok, doleance} =
        %Doleance{}
        |> Doleance.changeset(%{
          "title" => "doléance",
          "description" => "Plainte exemple pour test de permissions.",
          "building_id" => building.id,
          "author_id" => reporter.id
        })
        |> Repo.insert()

      assert {:error, :forbidden} =
               Incidents.link_doleance(incident, doleance.id, reporter)
    end
  end

  defp close_status!(%Incident{} = inc, status) do
    inc
    |> Incident.changeset(%{status: status})
    |> Repo.update!()
  end
end
