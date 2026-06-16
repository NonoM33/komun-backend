defmodule KomunBackendWeb.ResidenceCaseControllerTest do
  @moduledoc """
  Couvre les endpoints `POST /api/v1/residences/:rid/{incidents,
  doleances, diligences}` qui créent un dossier rattaché à la résidence
  entière. Le focus est l'**authorization** :

    * incident / doléance : tout user membre d'au moins un bâtiment de
      la résidence est autorisé.
    * diligence : seuls les rôles privilégiés (syndic / CS / super_admin).
    * Tous : 403 si l'utilisateur n'est membre d'aucun bâtiment de la
      résidence et n'est pas super_admin global.

  On vérifie aussi que le dossier créé est ensuite visible dans le GET
  building-scoped (les listes par bâtiment incluent les sujets résidence).
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
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

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "1 rue Test",
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

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_residence_with_two_buildings_and_member(member_role \\ :coproprietaire) do
    residence = insert_residence!()
    building_a = insert_building!(residence)
    building_b = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building_a.id, user.id, member_role)
    {residence, building_a, building_b, user}
  end

  describe "POST /api/v1/residences/:rid/incidents" do
    test "crée un incident résidence-scoped (copropriétaire d'un des bâtiments)", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/incidents", %{
          "incident" => %{
            "title" => "Vice de construction commun aux deux bâtiments",
            "description" => "Fissures sur les façades extérieures partagées",
            "category" => "facades",
            "severity" => "high",
            "status" => "brouillon"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] =~ "Vice de construction"
      assert data["residence_id"] == residence.id
      assert is_nil(data["building_id"])
    end

    test "renvoie 403 si user n'est membre d'aucun bâtiment de la résidence", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      stranger = insert_user!()

      conn =
        conn
        |> authed(stranger)
        |> post(~p"/api/v1/residences/#{residence.id}/incidents", %{
          "incident" => %{
            "title" => "Tentative",
            "description" => "Pas autorisé",
            "category" => "autre"
          }
        })

      assert json_response(conn, 403)
    end

    test "le dossier résidence apparaît dans le GET /buildings/:bid/incidents", %{conn: conn} do
      {residence, ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      _ =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/incidents", %{
          "incident" => %{
            "title" => "Sujet partagé entre bâtiments",
            "description" => "Concerne tous les copropriétaires",
            "category" => "parties_communes"
          }
        })
        |> json_response(201)

      # Liste vue depuis le bâtiment A — doit inclure le résidence-scoped
      conn =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{ba.id}/incidents")

      body = json_response(conn, 200)
      titles = body["data"] |> Enum.map(& &1["title"])
      assert "Sujet partagé entre bâtiments" in titles
    end
  end

  describe "POST /api/v1/residences/:rid/doleances" do
    test "crée une doléance résidence-scoped", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "Voirie commune dégradée",
            "description" => "Les allées de la résidence sont défoncées",
            "category" => "voirie_parking"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["residence_id"] == residence.id
      assert is_nil(data["building_id"])
    end

    test "renvoie 403 à un non-membre", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      stranger = insert_user!()

      conn =
        conn
        |> authed(stranger)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "X",
            "description" => "Pas autorisé",
            "category" => "autre"
          }
        })

      assert json_response(conn, 403)
    end
  end

  describe "PUT /api/v1/residences/:rid/doleances/:id" do
    test "auteur peut éditer sa doléance résidence", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id}} =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "Titre initial",
            "description" => "Desc initiale",
            "category" => "voirie_parking"
          }
        })
        |> json_response(201)

      conn =
        conn
        |> authed(user)
        |> put(~p"/api/v1/residences/#{residence.id}/doleances/#{id}", %{
          "doleance" => %{"title" => "Titre modifié"}
        })

      assert %{"data" => %{"title" => "Titre modifié"}} = json_response(conn, 200)
    end

    test "renvoie 404 si l'id appartient à une autre résidence", %{conn: conn} do
      # Résidence A avec membre user_a + doléance dans A
      {res_a, _ba, _bb, user_a} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id_in_a}} =
        conn
        |> authed(user_a)
        |> post(~p"/api/v1/residences/#{res_a.id}/doleances", %{
          "doleance" => %{
            "title" => "Doléance A",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "voirie_parking"
          }
        })
        |> json_response(201)

      # Résidence B avec un autre membre user_b
      {res_b, _bb_a, _bb_b, user_b} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user_b)
        |> put(~p"/api/v1/residences/#{res_b.id}/doleances/#{id_in_a}", %{
          "doleance" => %{"title" => "Pwn"}
        })

      assert json_response(conn, 404)
    end

    test "renvoie 403 si copro lambda non-auteur tente d'éditer", %{conn: conn} do
      {residence, ba, _bb, author} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id}} =
        conn
        |> authed(author)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "Ma doléance",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "autre"
          }
        })
        |> json_response(201)

      # Autre copro membre du même bâtiment, mais pas auteur
      other = insert_user!()
      {:ok, _} = Buildings.add_member(ba.id, other.id, :coproprietaire)

      conn =
        conn
        |> authed(other)
        |> put(~p"/api/v1/residences/#{residence.id}/doleances/#{id}", %{
          "doleance" => %{"title" => "Hack"}
        })

      assert json_response(conn, 403)
    end

    test "président du CS peut éditer une doléance d'un autre copro", %{conn: conn} do
      {residence, ba, _bb, author} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id}} =
        conn
        |> authed(author)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "Sujet collectif",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "structure"
          }
        })
        |> json_response(201)

      cs = insert_user!()
      {:ok, _} = Buildings.add_member(ba.id, cs.id, :president_cs)

      conn =
        conn
        |> authed(cs)
        |> put(~p"/api/v1/residences/#{residence.id}/doleances/#{id}", %{
          "doleance" => %{"status" => "rejected"}
        })

      assert %{"data" => %{"status" => "rejected"}} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/v1/residences/:rid/doleances/:id" do
    test "auteur peut supprimer sa doléance résidence", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id}} =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "À supprimer",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "autre"
          }
        })
        |> json_response(201)

      conn =
        conn
        |> authed(user)
        |> delete(~p"/api/v1/residences/#{residence.id}/doleances/#{id}")

      assert response(conn, 204)
      assert is_nil(KomunBackend.Doleances.get_doleance(id))
    end

    test "super_admin peut supprimer même sans être membre", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id}} =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "À supprimer par admin",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "autre"
          }
        })
        |> json_response(201)

      admin = insert_user!(:super_admin)

      conn =
        conn
        |> authed(admin)
        |> delete(~p"/api/v1/residences/#{residence.id}/doleances/#{id}")

      assert response(conn, 204)
    end

    test "renvoie 403 si copro lambda non-auteur tente de supprimer", %{conn: conn} do
      {residence, ba, _bb, author} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id}} =
        conn
        |> authed(author)
        |> post(~p"/api/v1/residences/#{residence.id}/doleances", %{
          "doleance" => %{
            "title" => "Ma doléance",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "autre"
          }
        })
        |> json_response(201)

      other = insert_user!()
      {:ok, _} = Buildings.add_member(ba.id, other.id, :coproprietaire)

      conn =
        conn
        |> authed(other)
        |> delete(~p"/api/v1/residences/#{residence.id}/doleances/#{id}")

      assert json_response(conn, 403)
      assert KomunBackend.Doleances.get_doleance(id)
    end

    test "renvoie 404 si l'id appartient à une autre résidence", %{conn: conn} do
      {res_a, _ba, _bb, user_a} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => id_in_a}} =
        conn
        |> authed(user_a)
        |> post(~p"/api/v1/residences/#{res_a.id}/doleances", %{
          "doleance" => %{
            "title" => "Doléance A",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "autre"
          }
        })
        |> json_response(201)

      {res_b, _bb_a, _bb_b, user_b} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user_b)
        |> delete(~p"/api/v1/residences/#{res_b.id}/doleances/#{id_in_a}")

      assert json_response(conn, 404)
      assert KomunBackend.Doleances.get_doleance(id_in_a)
    end

    test "ne peut pas supprimer une doléance building-scope via la route résidence", %{conn: conn} do
      # Régression : la route résidence ne doit accepter QUE les doléances
      # résidence-scoped (residence_id non null). Sinon on contournerait
      # l'authz building-scope.
      {residence, ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      %{"data" => %{"id" => building_doleance_id}} =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{ba.id}/doleances", %{
          "doleance" => %{
            "title" => "Building-scope",
            "description" => "Description suffisamment longue pour passer la validation.",
            "category" => "autre"
          }
        })
        |> json_response(201)

      conn =
        conn
        |> authed(user)
        |> delete(~p"/api/v1/residences/#{residence.id}/doleances/#{building_doleance_id}")

      assert json_response(conn, 404)
      assert KomunBackend.Doleances.get_doleance(building_doleance_id)
    end
  end

  describe "POST /api/v1/residences/:rid/diligences" do
    test "crée une diligence résidence-scoped pour un président_cs", %{conn: conn} do
      {residence, _ba, _bb, user} =
        setup_residence_with_two_buildings_and_member(:president_cs)

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/diligences", %{
          "diligence" => %{
            "title" => "Procédure trouble anormal — résidence",
            "description" => "Sujet transverse à toute la résidence",
            "source_type" => "copro_owner"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["residence_id"] == residence.id
      assert is_nil(data["building_id"])
    end

    test "renvoie 403 à un copropriétaire standard (diligence = privilégiés only)", %{conn: conn} do
      {residence, _ba, _bb, user} = setup_residence_with_two_buildings_and_member()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/residences/#{residence.id}/diligences", %{
          "diligence" => %{"title" => "Tentative interdite"}
        })

      assert json_response(conn, 403)
    end

    test "autorise un super_admin global même non-membre", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      admin = insert_user!(:super_admin)

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/residences/#{residence.id}/diligences", %{
          "diligence" => %{
            "title" => "Procédure résidence par super_admin",
            "description" => "Test",
            "source_type" => "unknown"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["residence_id"] == residence.id
    end
  end

  describe "résidence inexistante" do
    test "renvoie 404 sur les 3 endpoints", %{conn: conn} do
      user = insert_user!()
      fake_id = Ecto.UUID.generate()

      for path <- [
            ~p"/api/v1/residences/#{fake_id}/incidents",
            ~p"/api/v1/residences/#{fake_id}/doleances",
            ~p"/api/v1/residences/#{fake_id}/diligences"
          ] do
        conn = conn |> authed(user) |> post(path, %{})
        assert json_response(conn, 404)
      end
    end
  end
end
