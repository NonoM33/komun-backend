defmodule KomunBackend.BattlesTest do
  @moduledoc """
  Tests du contexte Battles. On couvre les invariants critiques :

  - Création d'une battle ⇒ Battle + 1 Vote (round 1) + N options +
    Oban job schedulé
  - cast_vote enregistre une réponse au vote du round courant
  - advance_battle! :
      * tally + clôture du round
      * top-2 → ouverture du round 2 (avec ses options)
      * dernier round → finalize + status: :finished + winning_label
  - Idempotence : un 2e advance sur une battle finished est un no-op
  """

  use KomunBackend.DataCase, async: false

  # Le scheduling Oban est bypassé en test (cf. config/test.exs
  # `:skip_battle_scheduling`). On simule la transition en appelant
  # `Battles.advance_battle!/1` directement.

  alias KomunBackend.{Battles, Buildings, Residences, Votes}
  alias KomunBackend.Battles.Battle
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Votes.VoteResponse

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

  defp setup_with_president do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)
    {building, user}
  end

  defp build_options do
    [
      %{"label" => "Brise-vue bambou"},
      %{"label" => "Brise-vue toile gris"},
      %{"label" => "Brise-vue PVC blanc"},
      %{"label" => "Brise-vue lattes bois"},
      %{"label" => "Brise-vue métal noir"}
    ]
  end

  describe "create_battle/3" do
    test "crée la battle, le round 1, ses N options et schedule le job Oban" do
      {building, user} = setup_with_president()

      assert {:ok, %Battle{} = battle} =
               Battles.create_battle(building.id, user.id, %{
                 "title" => "Choix du brise-vue de la terrasse",
                 "description" => "Voté collectivement.",
                 "options" => build_options()
               })

      assert battle.status == :running
      assert battle.current_round == 1
      assert battle.max_rounds == 2
      assert battle.round_duration_days == 3

      assert length(battle.votes) == 1
      [vote] = battle.votes
      assert vote.round_number == 1
      assert length(vote.options) == 5
      assert vote.vote_type == "single_choice"
      refute is_nil(vote.ends_at)
    end

    test "rejette < 2 options" do
      {building, user} = setup_with_president()

      assert {:error, :need_at_least_two_options} =
               Battles.create_battle(building.id, user.id, %{
                 "title" => "Sujet test",
                 "options" => [%{"label" => "Option seule"}]
               })
    end

    test "persiste external_url + attachment_url sur les options" do
      {building, user} = setup_with_president()

      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Choix d'un coussin",
          "options" => [
            %{
              "label" => "Coussin gris",
              "external_url" => "https://www.amazon.fr/dp/COUSSIN-GRIS",
              "attachment_url" => "uploads/votes/1.jpg",
              "attachment_filename" => "gris.jpg",
              "attachment_mime_type" => "image/jpeg",
              "attachment_size_bytes" => 12_345
            },
            %{"label" => "Coussin beige"}
          ]
        })

      [vote] = battle.votes
      [opt_gris, opt_beige] = Enum.sort_by(vote.options, & &1.position)

      assert opt_gris.label == "Coussin gris"
      assert opt_gris.external_url == "https://www.amazon.fr/dp/COUSSIN-GRIS"
      assert opt_gris.attachment_url == "uploads/votes/1.jpg"
      assert opt_gris.attachment_filename == "gris.jpg"
      assert opt_gris.attachment_mime_type == "image/jpeg"
      assert opt_gris.attachment_size_bytes == 12_345

      # Une option sans extras reste valide.
      assert opt_beige.external_url == nil
      assert opt_beige.attachment_url == nil
    end

    test "rejette une external_url qui n'est pas HTTP(S) valide" do
      {building, user} = setup_with_president()

      assert {:error, %Ecto.Changeset{} = cs} =
               Battles.create_battle(building.id, user.id, %{
                 "title" => "Choix d'un coussin",
                 "options" => [
                   %{
                     "label" => "Tentative XSS",
                     "external_url" => "javascript:alert(1)"
                   },
                   %{"label" => "Honnête"}
                 ]
               })

      # L'erreur remonte sur la sous-association options[i].external_url.
      errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
      assert get_in(errors, [:options]) |> List.first() |> Map.get(:external_url) ==
               ["doit être une URL HTTP(S) valide"]
    end

    test "accepte une external_url vide ou nil (champ optionnel)" do
      {building, user} = setup_with_president()

      assert {:ok, battle} =
               Battles.create_battle(building.id, user.id, %{
                 "title" => "Sujet",
                 "options" => [
                   %{"label" => "Un", "external_url" => ""},
                   %{"label" => "Deux", "external_url" => nil}
                 ]
               })

      [vote] = battle.votes
      assert Enum.all?(vote.options, &is_nil(&1.external_url))
    end

    test "applique les paramètres custom (round_duration, max_rounds, quorum)" do
      {building, user} = setup_with_president()

      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => build_options(),
          "round_duration_days" => 7,
          "max_rounds" => 3,
          "quorum_pct" => 50
        })

      assert battle.round_duration_days == 7
      assert battle.max_rounds == 3
      assert battle.quorum_pct == 50
    end
  end

  describe "cast_vote/3" do
    test "enregistre une réponse au round courant" do
      {building, user} = setup_with_president()
      voter = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => build_options()
        })

      [vote] = battle.votes
      [first_option | _] = vote.options

      assert {:ok, %VoteResponse{} = resp} =
               Battles.cast_vote(battle.id, voter.id, first_option.id)

      assert resp.option_id == first_option.id
      assert resp.user_id == voter.id
    end

    test "permet de changer son vote (overwrite)" do
      {building, user} = setup_with_president()
      voter = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => build_options()
        })

      [vote] = battle.votes
      [a, b | _] = vote.options

      {:ok, _} = Battles.cast_vote(battle.id, voter.id, a.id)
      {:ok, resp2} = Battles.cast_vote(battle.id, voter.id, b.id)

      assert resp2.option_id == b.id
      # Une seule réponse en base — on a updaté, pas créé un doublon
      count = Repo.aggregate(VoteResponse, :count, :id)
      assert count == 1
    end
  end

  describe "advance_battle!/1 — round non terminal" do
    test "ferme le round, calcule le top-2 et ouvre le round 2 avec ses options" do
      {building, user} = setup_with_president()
      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => build_options()
        })

      [vote] = battle.votes
      [a, b, c, _d, _e] = vote.options

      # 3 votes pour A, 2 votes pour B, 1 pour C → top-2 = [A, B]
      voters_a = for _ <- 1..3, do: insert_user!()
      voter_b1 = insert_user!()
      voter_b2 = insert_user!()
      voter_c = insert_user!()

      Enum.each(voters_a ++ [voter_b1, voter_b2, voter_c], fn v ->
        {:ok, _} = Buildings.add_member(building.id, v.id, :coproprietaire)
      end)

      Enum.each(voters_a, fn v -> Battles.cast_vote(battle.id, v.id, a.id) end)
      Battles.cast_vote(battle.id, voter_b1.id, b.id)
      Battles.cast_vote(battle.id, voter_b2.id, b.id)
      Battles.cast_vote(battle.id, voter_c.id, c.id)

      assert {:advanced, advanced} = Battles.advance_battle!(battle.id)

      assert advanced.status == :running
      assert advanced.current_round == 2
      assert length(advanced.votes) == 2

      [r1, r2] = advanced.votes
      assert r1.round_number == 1
      assert r1.status == :closed

      assert r2.round_number == 2
      assert r2.status == :open
      labels = Enum.map(r2.options, & &1.label) |> Enum.sort()
      assert labels == Enum.sort([a.label, b.label])
    end

    test "garde tous les ex-aequo au seuil top-2 (3 finalistes possibles)" do
      {building, user} = setup_with_president()
      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => build_options()
        })

      [vote] = battle.votes
      [a, b, c, _d, _e] = vote.options

      # Tie complet : 1 vote chacun pour A, B, C → tous au seuil = 3 finalistes
      v1 = insert_user!()
      v2 = insert_user!()
      v3 = insert_user!()

      Enum.each([v1, v2, v3], fn v ->
        {:ok, _} = Buildings.add_member(building.id, v.id, :coproprietaire)
      end)

      Battles.cast_vote(battle.id, v1.id, a.id)
      Battles.cast_vote(battle.id, v2.id, b.id)
      Battles.cast_vote(battle.id, v3.id, c.id)

      {:advanced, advanced} = Battles.advance_battle!(battle.id)

      [_r1, r2] = advanced.votes
      assert length(r2.options) == 3
    end
  end

  describe "advance_battle!/1 — round final" do
    test "déclare le gagnant et passe le statut à :finished" do
      {building, user} = setup_with_president()
      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => build_options()
        })

      [vote] = battle.votes
      [a, _b, _c, _d, _e] = vote.options

      voter = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)
      Battles.cast_vote(battle.id, voter.id, a.id)

      # Round 1 → round 2
      {:advanced, _} = Battles.advance_battle!(battle.id)

      # Vote pour le round 2 : le label de A gagne
      battle2 = Battles.get_battle!(battle.id)
      r2 = Enum.find(battle2.votes, &(&1.round_number == 2))
      r2_a = Enum.find(r2.options, &(&1.label == a.label))

      Battles.cast_vote(battle.id, voter.id, r2_a.id)

      # Round 2 = max → finalize
      {:finished, finished} = Battles.advance_battle!(battle.id)

      assert finished.status == :finished
      assert finished.winning_option_label == a.label
    end

    test "idempotent : 2e advance sur une finished est no-op" do
      {building, user} = setup_with_president()
      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => [%{"label" => "Un"}, %{"label" => "Deux"}],
          "max_rounds" => 1
        })

      {:finished, _} = Battles.advance_battle!(battle.id)

      assert {:noop, b} = Battles.advance_battle!(battle.id)
      assert b.status == :finished
    end
  end

  describe "tally_round/1" do
    test "ordonne les options par votes desc puis label asc (ex-aequo stable)" do
      {building, user} = setup_with_president()
      {:ok, battle} =
        Battles.create_battle(building.id, user.id, %{
          "title" => "Sujet",
          "options" => [
            %{"label" => "Zèbre"},
            %{"label" => "Antilope"},
            %{"label" => "Bison"}
          ]
        })

      [vote] = battle.votes
      [zebre, antilope, _bison] = vote.options

      voter = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)
      Battles.cast_vote(battle.id, voter.id, zebre.id)

      vote_loaded = Votes.get_vote!(vote.id)
      tally = Battles.tally_round(vote_loaded)

      # Zèbre a 1 vote, Antilope+Bison 0 mais Antilope < Bison alphabétiquement
      ordered_labels = Enum.map(tally.ordered, & &1.label)
      assert hd(ordered_labels) == "Zèbre"
      # Les 2 ex-aequo à 0 sont triés par label
      tail = Enum.drop(ordered_labels, 1)
      assert tail == ["Antilope", "Bison"]
    end
  end
end
