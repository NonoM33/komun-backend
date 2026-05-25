defmodule KomunBackendWeb.BattleControllerTest do
  @moduledoc """
  Tests HTTP de `BattleController`. La cible historique est la création
  d'une battle via `POST /api/v1/buildings/:bid/battles` — c'est là que
  vivait le bug « Une battle exige au moins 2 options » déclenché à tort
  quand une option transportait une photo.
  """

  use KomunBackendWeb.ConnCase, async: false

  import Ecto.Query

  alias KomunBackend.{Battles, Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Battles.Battle
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Votes.{Vote, VoteOption, VoteResponse}

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

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # NB : `BattleController.require_privileged/1` se base sur le rôle
  # GLOBAL (`user.role`), pas sur le rôle de membre du bâtiment — donc on
  # crée le user en `:syndic_manager` pour passer la garde HTTP.
  defp setup_with_privileged do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!(:syndic_manager)
    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)
    {building, user}
  end

  describe "POST /api/v1/buildings/:bid/battles" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "battle-test-#{System.unique_integer([:positive])}.png")

      # 1×1 PNG (header + IDAT) — suffisant pour KomunBackend.Votes.Uploads.
      png =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
          1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 0,
          1, 0, 0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      File.write!(tmp, png)
      on_exit(fn -> File.rm(tmp) end)
      {:ok, tmp: tmp}
    end

    test "régression — accepte les options en multipart (map indexée par Plug)",
         %{conn: conn, tmp: tmp} do
      # Reproduction directe du bug remonté : le frontend envoie les
      # options sous la forme `options[0][label]=…&options[1][label]=…`
      # en multipart. Plug parse ça en `%{"0" => %{...}, "1" => %{...}}` —
      # une map indexée, pas une liste. Avant le fix, le contrôleur
      # bypassait silencieusement les options et la création échouait
      # avec "Une battle exige au moins 2 options" alors que l'utilisateur
      # en avait posté 3.
      {building, user} = setup_with_privileged()

      upload = %Plug.Upload{
        path: tmp,
        filename: "classic.png",
        content_type: "image/png"
      }

      params = %{
        "battle" => %{
          "title" => "Brise-vue terrasse",
          "round_duration_days" => "3",
          "max_rounds" => "2",
          "quorum_pct" => "30"
        },
        "options" => %{
          "0" => %{"label" => "Le classic", "file" => upload},
          "1" => %{"label" => "Le deuxième"},
          "2" => %{"label" => "Le troisième"}
        }
      }

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Brise-vue terrasse"
      assert [round1] = data["rounds"]
      assert length(round1["options"]) == 3

      labels = round1["options"] |> Enum.map(& &1["label"]) |> Enum.sort()
      assert labels == ["Le classic", "Le deuxième", "Le troisième"]

      # L'ordre d'origine (0 → classic, 1 → deuxième, 2 → troisième) doit
      # être préservé : la normalisation trie les clés "0", "1", "2"
      # comme entiers.
      [opt0, opt1, opt2] = Enum.sort_by(round1["options"], & &1["position"])
      assert opt0["label"] == "Le classic"
      assert opt0["attachment_url"] =~ "uploads/votes/"
      assert opt1["label"] == "Le deuxième"
      assert opt2["label"] == "Le troisième"
    end

    test "chemin JSON — accepte les options en liste (path historique)",
         %{conn: conn} do
      {building, user} = setup_with_privileged()

      params = %{
        "battle" => %{
          "title" => "Choix du nouveau code couleur",
          "options" => [
            %{"label" => "Bleu nuit"},
            %{"label" => "Vert sauge"}
          ]
        }
      }

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Choix du nouveau code couleur"
      assert [round1] = data["rounds"]
      assert length(round1["options"]) == 2
    end

    test "rejette une battle sans option", %{conn: conn} do
      {building, user} = setup_with_privileged()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", %{
          "battle" => %{"title" => "Vide"}
        })

      assert %{"error" => err} = json_response(conn, 422)
      assert err =~ "au moins 2"
    end

    test "rejette une battle avec une seule option (multipart indexé)",
         %{conn: conn} do
      # On garde la garantie business : même via le chemin multipart, une
      # battle à 1 option doit être refusée — sinon la normalisation
      # masquerait la règle métier.
      {building, user} = setup_with_privileged()

      params = %{
        "battle" => %{"title" => "Choix unique"},
        "options" => %{
          "0" => %{"label" => "Solo"}
        }
      }

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", params)

      assert %{"error" => err} = json_response(conn, 422)
      assert err =~ "au moins 2"
    end

    # Hotfix 2026-05-25 : non-régression sur le gating CS/syndic.
    # Avant, le `with :ok <- require_privileged(user)` faisait
    # fall-through → 500 silencieux pour un copro lambda. La battle
    # n'était pas créée (donc pas de faille de sécurité), mais l'UX
    # était trompeuse — l'utilisateur croyait à un bug serveur. On a
    # déplacé le check en `cond` inline qui halte avec 403 propre.
    test "403 propre pour un copropriétaire lambda (pas de battle créée en DB)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      voisin = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voisin.id, :coproprietaire)

      conn =
        conn
        |> authed(voisin)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", %{
          "battle" => %{
            "title" => "Tentative copro",
            "options" => [%{"label" => "A"}, %{"label" => "B"}]
          }
        })

      assert %{"error" => err} = json_response(conn, 403)
      assert err =~ "conseil syndical"

      # Garantie de non-création — pas de battle insérée en DB malgré
      # la tentative.
      assert Repo.aggregate(
               from(b in Battle, where: b.building_id == ^building.id),
               :count
             ) == 0
    end

    test "403 propre sur /advance pour un copropriétaire lambda",
         %{conn: conn} do
      {building, admin} = setup_with_privileged()

      {:ok, battle} =
        Battles.create_battle(building.id, admin.id, %{
          "title" => "Pour test advance",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      voisin = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voisin.id, :coproprietaire)

      conn =
        conn
        |> authed(voisin)
        |> post(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/advance", %{})

      assert json_response(conn, 403)
    end
  end

  describe "DELETE /api/v1/buildings/:bid/battles/:id" do
    # Création d'une battle complète via le contexte (round 1 + 2 options
    # + 1 vote_response) — c'est ce qu'on cherche à voir disparaître après
    # un DELETE admin. On fait passer la création par `Battles.create_battle/3`
    # pour garder le même chemin que la prod (insertion + scheduling Oban).
    defp create_battle_with_response!(building, creator, voter) do
      {:ok, battle} =
        Battles.create_battle(building.id, creator.id, %{
          "title" => "Vote canapé hall",
          "options" => [
            %{"label" => "Velours vert"},
            %{"label" => "Cuir camel"}
          ]
        })

      [vote] = Repo.all(from v in Vote, where: v.battle_id == ^battle.id)
      [opt | _] = Repo.all(from o in VoteOption, where: o.vote_id == ^vote.id)

      {:ok, _} =
        %VoteResponse{}
        |> VoteResponse.changeset(%{
          vote_id: vote.id,
          user_id: voter.id,
          option_id: opt.id
        })
        |> Repo.insert()

      battle
    end

    test "supprime la battle, ses votes et leurs réponses (admin)", %{conn: conn} do
      {building, admin} = setup_with_privileged()
      voter = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      battle = create_battle_with_response!(building, admin, voter)

      conn =
        conn
        |> authed(admin)
        |> delete(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}")

      assert response(conn, 204)

      # Battle effacée + cascade vers Vote + VoteOption + VoteResponse.
      refute Repo.get(Battle, battle.id)
      assert Repo.aggregate(from(v in Vote, where: v.battle_id == ^battle.id), :count) == 0
    end

    test "404 si la battle n'appartient pas au bâtiment de l'URL", %{conn: conn} do
      # Garantit qu'on ne peut pas effacer la battle du bâtiment voisin
      # juste en swappant le `building_id` dans l'URL.
      {building_a, admin} = setup_with_privileged()

      residence_b = insert_residence!()
      building_b = insert_building!(residence_b)
      {:ok, _} = Buildings.add_member(building_b.id, admin.id, :president_cs)

      battle = create_battle_with_response!(building_b, admin, admin)

      conn =
        conn
        |> authed(admin)
        |> delete(~p"/api/v1/buildings/#{building_a.id}/battles/#{battle.id}")

      assert json_response(conn, 404)
      assert Repo.get(Battle, battle.id)
    end

    test "403 pour un copropriétaire non privilégié", %{conn: conn} do
      {building, admin} = setup_with_privileged()
      battle = create_battle_with_response!(building, admin, admin)

      resident = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, resident.id, :coproprietaire)

      conn =
        conn
        |> authed(resident)
        |> delete(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}")

      assert json_response(conn, 403)
      assert Repo.get(Battle, battle.id)
    end
  end

  describe "GET /api/v1/residences/:rid/battles" do
    # Régression pour l'incident prod du 2026-05-25 : la battle « Choix
    # des brises vues » créée sur Bât. A était invisible à Coralie
    # (membre_cs sur A ET B) parce que le frontend interrogeait
    # `/buildings/B/battles` quand son building courant était B. La page
    # `/battles` du front est désormais résidence-scope ; ce test garde
    # la garantie que l'endpoint backend renvoie bien les battles des
    # deux bâtiments en un seul appel.
    test "renvoie les battles de TOUS les bâtiments où l'user est membre",
         %{conn: conn} do
      residence = insert_residence!()
      building_a = insert_building!(residence)
      building_b = insert_building!(residence)

      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building_a.id, creator.id, :president_cs)
      {:ok, _} = Buildings.add_member(building_b.id, creator.id, :president_cs)

      {:ok, battle_a} =
        Battles.create_battle(building_a.id, creator.id, %{
          "title" => "Choix brise-vue Bât. A",
          "options" => [%{"label" => "Gris"}, %{"label" => "Beige"}]
        })

      {:ok, battle_b} =
        Battles.create_battle(building_b.id, creator.id, %{
          "title" => "Choix peinture cage Bât. B",
          "options" => [%{"label" => "Blanc"}, %{"label" => "Crème"}]
        })

      coralie = insert_user!(:membre_cs)
      {:ok, _} = Buildings.add_member(building_a.id, coralie.id, :membre_cs)
      {:ok, _} = Buildings.add_member(building_b.id, coralie.id, :membre_cs)

      conn =
        conn
        |> authed(coralie)
        |> get(~p"/api/v1/residences/#{residence.id}/battles")

      assert %{"data" => data} = json_response(conn, 200)
      ids = data |> Enum.map(& &1["id"]) |> Enum.sort()
      assert ids == Enum.sort([battle_a.id, battle_b.id])
    end

    test "filtre les bâtiments où l'user n'est PAS membre",
         %{conn: conn} do
      # Bâtiment B n'a pas notre user → la battle de B ne doit pas
      # remonter, même si la résidence est la même.
      residence = insert_residence!()
      building_a = insert_building!(residence)
      building_b = insert_building!(residence)

      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building_a.id, creator.id, :president_cs)
      {:ok, _} = Buildings.add_member(building_b.id, creator.id, :president_cs)

      {:ok, battle_a} =
        Battles.create_battle(building_a.id, creator.id, %{
          "title" => "Visible",
          "options" => [%{"label" => "X"}, %{"label" => "Y"}]
        })

      {:ok, battle_b} =
        Battles.create_battle(building_b.id, creator.id, %{
          "title" => "Cachée",
          "options" => [%{"label" => "X"}, %{"label" => "Y"}]
        })

      resident = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building_a.id, resident.id, :coproprietaire)

      conn =
        conn
        |> authed(resident)
        |> get(~p"/api/v1/residences/#{residence.id}/battles")

      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])
      assert battle_a.id in ids
      refute battle_b.id in ids
    end

    test "renvoie 403 à un user qui n'est membre d'aucun bâtiment",
         %{conn: conn} do
      residence = insert_residence!()
      _building = insert_building!(residence)
      outsider = insert_user!(:coproprietaire)

      conn =
        conn
        |> authed(outsider)
        |> get(~p"/api/v1/residences/#{residence.id}/battles")

      assert json_response(conn, 403)
    end

    test "super_admin voit tout, même sans membership (admin audit)", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building.id, creator.id, %{
          "title" => "Audit",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      admin = insert_user!(:super_admin)

      conn =
        conn
        |> authed(admin)
        |> get(~p"/api/v1/residences/#{residence.id}/battles")

      assert %{"data" => [returned]} = json_response(conn, 200)
      assert returned["id"] == battle.id
    end
  end

  describe "multi-choice voting (battle.vote_mode = :multiple_choice)" do
    # Feedback voisin du 2026-05-25 : « Pourquoi pas un vote à choix
    # multiples ? Plusieurs options peuvent convenir à quelqu'un. »
    # On valide que (a) un user peut cocher N options, (b) ses
    # responses sont remplacées en bloc à chaque cast, (c) le tally
    # compte chaque option indépendamment.

    test "POST avec option_ids enregistre N votes pour un même user",
         %{conn: conn} do
      {building, _admin} = setup_with_privileged()
      voter = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      {:ok, battle} =
        Battles.create_battle(building.id, voter.id, %{
          "title" => "Quel(s) brise-vue ?",
          "vote_mode" => "multiple_choice",
          "options" => [
            %{"label" => "Gris"},
            %{"label" => "Beige"},
            %{"label" => "Bambou"}
          ]
        })

      vote_round = hd(battle.votes)
      [o1, o2, _o3] = Enum.sort_by(vote_round.options, & &1.position)

      conn =
        conn
        |> authed(voter)
        |> post(
          ~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/vote",
          %{"option_ids" => [o1.id, o2.id]}
        )

      assert %{"data" => data} = json_response(conn, 200)
      [round] = data["rounds"]
      # Comme on est en multi : 2 lignes vote_response pour 1 user.
      assert round["total_votes"] == 1
      # Chaque option votée individuellement compte 1
      counts = round["options"] |> Enum.map(&{&1["label"], &1["votes"]}) |> Map.new()
      assert counts["Gris"] == 1
      assert counts["Beige"] == 1
      assert counts["Bambou"] == 0
      # own_option_ids contient les deux ids cochés
      assert Enum.sort(round["own_option_ids"]) == Enum.sort([o1.id, o2.id])
    end

    test "REMPLACE le set précédent — re-voter avec un set différent efface l'ancien",
         %{conn: conn} do
      {building, _admin} = setup_with_privileged()
      voter = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      {:ok, battle} =
        Battles.create_battle(building.id, voter.id, %{
          "title" => "Multi",
          "vote_mode" => "multiple_choice",
          "options" => [%{"label" => "A"}, %{"label" => "B"}, %{"label" => "C"}]
        })

      vote_round = hd(battle.votes)
      [o_a, o_b, o_c] = Enum.sort_by(vote_round.options, & &1.position)

      # 1er cast : A + B
      conn
      |> authed(voter)
      |> post(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/vote",
        %{"option_ids" => [o_a.id, o_b.id]}
      )

      # 2e cast : C uniquement → doit retirer A et B
      conn2 =
        build_conn()
        |> authed(voter)
        |> post(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/vote",
          %{"option_ids" => [o_c.id]}
        )

      assert %{"data" => data} = json_response(conn2, 200)
      [round] = data["rounds"]
      assert round["own_option_ids"] == [o_c.id]
      counts = round["options"] |> Enum.map(&{&1["label"], &1["votes"]}) |> Map.new()
      assert counts["A"] == 0
      assert counts["B"] == 0
      assert counts["C"] == 1
    end

    test "liste vide d'option_ids = abstention (efface les votes existants)",
         %{conn: conn} do
      {building, _admin} = setup_with_privileged()
      voter = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      {:ok, battle} =
        Battles.create_battle(building.id, voter.id, %{
          "title" => "Multi",
          "vote_mode" => "multiple_choice",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      [o_a, _o_b] =
        Enum.sort_by(hd(battle.votes).options, & &1.position)

      conn
      |> authed(voter)
      |> post(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/vote",
        %{"option_ids" => [o_a.id]}
      )

      conn2 =
        build_conn()
        |> authed(voter)
        |> post(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/vote",
          %{"option_ids" => []}
        )

      assert %{"data" => data} = json_response(conn2, 200)
      assert hd(data["rounds"])["own_option_ids"] == []
      assert hd(data["rounds"])["total_votes"] == 0
    end

    test "option_id inconnue → 422 invalid_option_ids",
         %{conn: conn} do
      {building, _admin} = setup_with_privileged()
      voter = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building.id, voter.id, :coproprietaire)

      {:ok, battle} =
        Battles.create_battle(building.id, voter.id, %{
          "title" => "Multi",
          "vote_mode" => "multiple_choice",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      bogus = Ecto.UUID.generate()

      conn =
        conn
        |> authed(voter)
        |> post(~p"/api/v1/buildings/#{building.id}/battles/#{battle.id}/vote",
          %{"option_ids" => [bogus]}
        )

      assert %{"error" => err, "invalid_option_ids" => ids} = json_response(conn, 422)
      assert err =~ "Option(s) inconnue(s)"
      assert ids == [bogus]
    end
  end

  describe "allow_none — option built-in « Aucune des propositions »" do
    # Feedback voisin Q1 : « il manque une option ne se prononce pas ».
    # Quand `allow_none: true`, on injecte automatiquement une option
    # à la sentinelle 9999, reconnaissable par `is_none: true` côté API.

    test "création avec allow_none=true ajoute l'option « Aucune des propositions »",
         %{conn: conn} do
      {building, admin} = setup_with_privileged()

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", %{
          "battle" => %{
            "title" => "Choix brise-vue",
            "allow_none" => true,
            "options" => [
              %{"label" => "Gris"},
              %{"label" => "Beige"}
            ]
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["allow_none"] == true
      [round] = data["rounds"]

      # 3 options : les 2 utilisateurs + « Aucune »
      assert length(round["options"]) == 3

      none_opt = Enum.find(round["options"], & &1["is_none"])
      assert none_opt
      assert none_opt["label"] == "Aucune des propositions"
      assert none_opt["position"] == 9999
    end

    test "création sans allow_none → pas d'option « Aucune » injectée",
         %{conn: conn} do
      {building, admin} = setup_with_privileged()

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/buildings/#{building.id}/battles", %{
          "battle" => %{
            "title" => "Sans abstention built-in",
            "options" => [%{"label" => "A"}, %{"label" => "B"}]
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["allow_none"] == false
      [round] = data["rounds"]
      assert length(round["options"]) == 2
      refute Enum.any?(round["options"], & &1["is_none"])
    end
  end

  describe "PATCH /api/v1/buildings/:bid/battles/:id (move to another building)" do
    # Le cas type : la battle a été créée sur le mauvais bâtiment par
    # erreur (la FAB « Créer » s'aligne sur le building courant du store).
    # L'admin doit pouvoir la rebrancher sur le bon bâtiment sans perdre
    # les votes déjà recueillis. Un voisin lambda n'a pas ce droit.
    test "déplace la battle vers un autre bâtiment de la même résidence",
         %{conn: conn} do
      residence = insert_residence!()
      building_a = insert_building!(residence)
      building_b = insert_building!(residence)

      admin = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building_a.id, admin.id, :president_cs)
      {:ok, _} = Buildings.add_member(building_b.id, admin.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building_a.id, admin.id, %{
          "title" => "À déplacer",
          "options" => [%{"label" => "X"}, %{"label" => "Y"}]
        })

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/v1/buildings/#{building_a.id}/battles/#{battle.id}",
          %{"battle" => %{"building_id" => building_b.id}}
        )

      assert %{"data" => data} = json_response(conn, 200)
      assert data["building_id"] == building_b.id

      # En DB aussi
      assert Repo.get!(Battle, battle.id).building_id == building_b.id
    end

    test "refuse de déplacer vers un bâtiment d'une AUTRE résidence",
         %{conn: conn} do
      residence_x = insert_residence!()
      residence_y = insert_residence!()

      building_x = insert_building!(residence_x)
      building_y = insert_building!(residence_y)

      admin = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building_x.id, admin.id, :president_cs)
      {:ok, _} = Buildings.add_member(building_y.id, admin.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building_x.id, admin.id, %{
          "title" => "Pas téléportable",
          "options" => [%{"label" => "X"}, %{"label" => "Y"}]
        })

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/v1/buildings/#{building_x.id}/battles/#{battle.id}",
          %{"battle" => %{"building_id" => building_y.id}}
        )

      assert %{"error" => err} = json_response(conn, 422)
      assert err =~ "même résidence"

      # En DB on n'a rien bougé
      assert Repo.get!(Battle, battle.id).building_id == building_x.id
    end

    test "refuse à un copropriétaire lambda (403)", %{conn: conn} do
      residence = insert_residence!()
      building_a = insert_building!(residence)
      building_b = insert_building!(residence)

      admin = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building_a.id, admin.id, :president_cs)
      {:ok, _} = Buildings.add_member(building_b.id, admin.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building_a.id, admin.id, %{
          "title" => "Pas touchable par tout le monde",
          "options" => [%{"label" => "X"}, %{"label" => "Y"}]
        })

      voisin = insert_user!(:coproprietaire)
      {:ok, _} = Buildings.add_member(building_a.id, voisin.id, :coproprietaire)

      conn =
        conn
        |> authed(voisin)
        |> patch(~p"/api/v1/buildings/#{building_a.id}/battles/#{battle.id}",
          %{"battle" => %{"building_id" => building_b.id}}
        )

      assert json_response(conn, 403)
      assert Repo.get!(Battle, battle.id).building_id == building_a.id
    end

    test "ignore tous les autres champs (cast strict)", %{conn: conn} do
      # Sécurité : un PATCH qui essaie de bouger title/status/current_round
      # au passage doit être no-op sur ces champs. Garantit qu'on ne casse
      # pas l'avancement du tournoi via une mise à jour innocente.
      residence = insert_residence!()
      building_a = insert_building!(residence)
      building_b = insert_building!(residence)

      admin = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building_a.id, admin.id, :president_cs)
      {:ok, _} = Buildings.add_member(building_b.id, admin.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building_a.id, admin.id, %{
          "title" => "Titre originel",
          "max_rounds" => 2,
          "options" => [%{"label" => "X"}, %{"label" => "Y"}]
        })

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/v1/buildings/#{building_a.id}/battles/#{battle.id}",
          %{
            "battle" => %{
              "building_id" => building_b.id,
              "title" => "TITRE HACKE",
              "status" => "finished",
              "current_round" => 99,
              "winning_option_label" => "PWNED"
            }
          }
        )

      assert json_response(conn, 200)

      reloaded = Repo.get!(Battle, battle.id)
      assert reloaded.building_id == building_b.id
      assert reloaded.title == "Titre originel"
      assert reloaded.status == :running
      assert reloaded.current_round == 1
      assert reloaded.winning_option_label == nil
    end
  end
end
