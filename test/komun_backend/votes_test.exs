defmodule KomunBackend.VotesTest do
  @moduledoc """
  Coverage of the Votes context after the rich-vote refactor (avril 2026) :
  vote_type binary vs single_choice, options, attachments, project linking,
  and the `respond/3` polymorphism (choice vs option_id).

  Volet "non-régression" : on garde un test qui crée un vote binaire et y
  répond yes/no/abstain — ça gèle le comportement historique.
  """

  use KomunBackend.DataCase, async: true

  alias KomunBackend.{Votes, Residences, Buildings}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Projects.Project
  alias KomunBackend.Votes.{Vote, VoteOption, VoteAttachment, VoteResponse}

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
      address: "1 rue du Vote",
      city: "Paris",
      postal_code: "75001",
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

  defp insert_project!(building_id, user_id) do
    %Project{}
    |> Project.changeset(%{
      title: "Ravalement façade #{System.unique_integer([:positive])}",
      building_id: building_id,
      created_by_id: user_id
    })
    |> Repo.insert!()
  end

  defp setup_actors do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    %{building: building, user: user}
  end

  # ── create_vote ──────────────────────────────────────────────────────────

  describe "create_vote/3 — binary (non-régression)" do
    test "crée un vote binaire avec les valeurs par défaut" do
      %{building: b, user: u} = setup_actors()

      assert {:ok, vote} =
               Votes.create_vote(b.id, u.id, %{
                 "title" => "Ravalement façade",
                 "description" => "Voir devis CS",
                 "is_anonymous" => false
               })

      assert vote.title == "Ravalement façade"
      assert vote.vote_type == "binary"
      assert vote.status == :open
      assert vote.options == []
      assert vote.attachments == []
      assert vote.project_id == nil
    end

    test "rejette un titre trop court" do
      %{building: b, user: u} = setup_actors()

      assert {:error, %Ecto.Changeset{} = cs} =
               Votes.create_vote(b.id, u.id, %{"title" => "Hi"})

      assert "should be at least 3 character(s)" in errors_on(cs).title
    end
  end

  describe "create_vote/3 — single_choice avec options" do
    test "crée un vote multi-choix avec ≥ 2 options" do
      %{building: b, user: u} = setup_actors()

      assert {:ok, vote} =
               Votes.create_vote(b.id, u.id, %{
                 "title" => "Quel devis pour la toiture ?",
                 "vote_type" => "single_choice",
                 "options" => [
                   %{"label" => "Entreprise A — 12 000 €", "position" => 0},
                   %{"label" => "Entreprise B — 14 500 €", "position" => 1},
                   %{"label" => "Entreprise C — 10 800 €", "position" => 2}
                 ]
               })

      assert vote.vote_type == "single_choice"
      assert length(vote.options) == 3
      labels = vote.options |> Enum.sort_by(& &1.position) |> Enum.map(& &1.label)
      assert labels == [
               "Entreprise A — 12 000 €",
               "Entreprise B — 14 500 €",
               "Entreprise C — 10 800 €"
             ]
    end

    test "refuse un single_choice avec moins de 2 options" do
      %{building: b, user: u} = setup_actors()

      assert {:error, %Ecto.Changeset{} = cs} =
               Votes.create_vote(b.id, u.id, %{
                 "title" => "Vote dégénéré",
                 "vote_type" => "single_choice",
                 "options" => [%{"label" => "Option unique"}]
               })

      assert errors_on(cs)[:options]
    end
  end

  describe "create_vote/3 — attachments" do
    test "persiste les attachments fournis avec leur kind" do
      %{building: b, user: u} = setup_actors()

      assert {:ok, vote} =
               Votes.create_vote(b.id, u.id, %{
                 "title" => "Vote avec photos",
                 "attachments" => [
                   %{"kind" => "photo", "file_url" => "uploads/votes/p1.jpg", "position" => 0},
                   %{"kind" => "document", "file_url" => "uploads/votes/d1.pdf", "position" => 0}
                 ]
               })

      assert length(vote.attachments) == 2
      assert Enum.any?(vote.attachments, &(&1.kind == "photo"))
      assert Enum.any?(vote.attachments, &(&1.kind == "document"))
    end

    test "refuse un attachment avec kind invalide" do
      %{building: b, user: u} = setup_actors()

      assert {:error, %Ecto.Changeset{}} =
               Votes.create_vote(b.id, u.id, %{
                 "title" => "Vote",
                 "attachments" => [
                   %{"kind" => "video", "file_url" => "uploads/votes/x.mp4"}
                 ]
               })
    end
  end

  describe "create_vote/3 — project linking" do
    test "set projects.vote_id sur le projet rattaché dans la même transaction" do
      %{building: b, user: u} = setup_actors()
      project = insert_project!(b.id, u.id)

      assert {:ok, vote} =
               Votes.create_vote(b.id, u.id, %{
                 "title" => "Vote rattaché au projet",
                 "project_id" => project.id
               })

      reloaded = Repo.get!(Project, project.id)
      assert reloaded.vote_id == vote.id
      assert vote.project_id == project.id
    end
  end

  # ── respond ──────────────────────────────────────────────────────────────

  describe "respond/3 — binary (non-régression)" do
    test "enregistre yes/no/abstain et upsert sur re-vote du même user" do
      %{building: b, user: u} = setup_actors()
      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Vote binaire"})

      assert {:ok, _} = Votes.respond(vote.id, u.id, %{"choice" => "yes"})
      assert Votes.has_voted?(vote.id, u.id)

      # Upsert : un même user qui re-vote update sa réponse au lieu de créer
      assert {:ok, _} = Votes.respond(vote.id, u.id, %{"choice" => "no"})

      [response] =
        Repo.all(from r in VoteResponse, where: r.vote_id == ^vote.id and r.user_id == ^u.id)

      assert response.choice == :no
    end

    test "tally compte yes/no/abstain" do
      %{building: b, user: u} = setup_actors()
      voter2 = insert_user!()
      voter3 = insert_user!()
      {:ok, vote} = Votes.create_vote(b.id, u.id, %{"title" => "Vote tally"})

      {:ok, _} = Votes.respond(vote.id, u.id, %{"choice" => "yes"})
      {:ok, _} = Votes.respond(vote.id, voter2.id, %{"choice" => "yes"})
      {:ok, _} = Votes.respond(vote.id, voter3.id, %{"choice" => "no"})

      reloaded = Votes.get_vote!(vote.id)
      assert Votes.tally(reloaded) == %{yes: 2, no: 1, abstain: 0, total: 3}
    end
  end

  describe "respond/3 — single_choice" do
    test "enregistre option_id quand l'option appartient au vote" do
      %{building: b, user: u} = setup_actors()

      {:ok, vote} =
        Votes.create_vote(b.id, u.id, %{
          "title" => "Quel devis ?",
          "vote_type" => "single_choice",
          "options" => [
            %{"label" => "A"},
            %{"label" => "B"}
          ]
        })

      [opt_a, _opt_b] = Enum.sort_by(vote.options, & &1.label)

      assert {:ok, _} = Votes.respond(vote.id, u.id, %{"option_id" => opt_a.id})

      [response] = Repo.all(from r in VoteResponse, where: r.vote_id == ^vote.id)
      assert response.option_id == opt_a.id
      assert response.choice == nil
    end

    test "refuse une option qui appartient à un autre vote" do
      %{building: b, user: u} = setup_actors()

      {:ok, vote_a} =
        Votes.create_vote(b.id, u.id, %{
          "title" => "Vote A",
          "vote_type" => "single_choice",
          "options" => [%{"label" => "A1"}, %{"label" => "A2"}]
        })

      {:ok, vote_b} =
        Votes.create_vote(b.id, u.id, %{
          "title" => "Vote B",
          "vote_type" => "single_choice",
          "options" => [%{"label" => "B1"}, %{"label" => "B2"}]
        })

      [opt_b1 | _] = vote_b.options

      assert {:error, _cs} = Votes.respond(vote_a.id, u.id, %{"option_id" => opt_b1.id})
    end

    test "exige option_id (pas de choice toléré sur single_choice)" do
      %{building: b, user: u} = setup_actors()

      {:ok, vote} =
        Votes.create_vote(b.id, u.id, %{
          "title" => "Vote",
          "vote_type" => "single_choice",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      assert {:error, _cs} = Votes.respond(vote.id, u.id, %{"choice" => "yes"})
    end

    test "option_tally compte les voix par option" do
      %{building: b, user: u} = setup_actors()
      voter2 = insert_user!()
      voter3 = insert_user!()

      {:ok, vote} =
        Votes.create_vote(b.id, u.id, %{
          "title" => "Quel devis ?",
          "vote_type" => "single_choice",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      [opt_a, opt_b] = Enum.sort_by(vote.options, & &1.label)

      {:ok, _} = Votes.respond(vote.id, u.id, %{"option_id" => opt_a.id})
      {:ok, _} = Votes.respond(vote.id, voter2.id, %{"option_id" => opt_a.id})
      {:ok, _} = Votes.respond(vote.id, voter3.id, %{"option_id" => opt_b.id})

      reloaded = Votes.get_vote!(vote.id)
      counts = Votes.option_tally(reloaded)
      assert counts[opt_a.id] == 2
      assert counts[opt_b.id] == 1
    end
  end

  # ── Schema-level guards ──────────────────────────────────────────────────

  describe "VoteResponse changeset" do
    test "refuse choice ET option_id en même temps" do
      cs = VoteResponse.changeset(%VoteResponse{}, %{
        vote_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        choice: "yes",
        option_id: Ecto.UUID.generate()
      })

      refute cs.valid?
      assert errors_on(cs)[:choice]
    end

    test "refuse ni choice ni option_id" do
      cs = VoteResponse.changeset(%VoteResponse{}, %{
        vote_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      })

      refute cs.valid?
      assert errors_on(cs)[:choice]
    end
  end

  describe "Vote schema invariants" do
    test "vote_type accepte uniquement binary | single_choice" do
      cs = Vote.changeset(%Vote{}, %{
        title: "test",
        vote_type: "ranked",
        building_id: Ecto.UUID.generate(),
        created_by_id: Ecto.UUID.generate()
      })

      refute cs.valid?
      assert errors_on(cs)[:vote_type]
    end
  end

  # Make sure Dialyzer doesn't complain about unused alias :)
  doctest_helper = [VoteOption, VoteAttachment]
  _ = doctest_helper
end
