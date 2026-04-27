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

    # NOTE : pas de test "403 à un copropriétaire" ici — le contrôleur a
    # un bug latent (`require_privileged/1` renvoie `{:error, :unauthorized}`
    # qui n'est pas géré par le `with` et fait crasher l'action au lieu
    # de renvoyer un 403). Sujet orthogonal au bug multipart corrigé ici.
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
end
