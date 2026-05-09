defmodule KomunBackendWeb.ContactControllerTest do
  @moduledoc """
  Couvre les endpoints CRUD `/api/v1/residences/:rid/contacts` (annuaire
  par résidence). Focus sur l'authorization :

    * lecture : tout membre d'au moins un bâtiment de la résidence
      (`super_admin` aussi). Étranger → 403.
    * écriture : conseil syndical / syndic / `super_admin`. Copro lambda → 403.

  Ainsi que la validation basique du changeset (nom requis, email valide,
  scope résidence respecté).
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Contacts, Repo, Residences}
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

  # Setup commun : une résidence avec un bâtiment, un copro lambda
  # membre du bâtiment, et un président CS lui aussi membre.
  defp setup_residence_with_member_and_president do
    residence = insert_residence!()
    building = insert_building!(residence)

    member = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, member.id, :coproprietaire)

    president = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

    {residence, building, member, president}
  end

  describe "GET /api/v1/residences/:rid/contacts" do
    test "liste vide pour un membre de la résidence", %{conn: conn} do
      {residence, _b, member, _p} = setup_residence_with_member_and_president()

      conn = conn |> authed(member) |> get(~p"/api/v1/residences/#{residence.id}/contacts")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "liste les contacts existants triés par nom", %{conn: conn} do
      {residence, _b, member, president} = setup_residence_with_member_and_president()

      {:ok, _} =
        Contacts.create_contact(residence.id, president.id, %{"name" => "Zorro Avocats"})

      {:ok, _} = Contacts.create_contact(residence.id, president.id, %{"name" => "Alpha Syndic"})

      conn = conn |> authed(member) |> get(~p"/api/v1/residences/#{residence.id}/contacts")

      assert %{"data" => [first, second]} = json_response(conn, 200)
      assert first["name"] == "Alpha Syndic"
      assert second["name"] == "Zorro Avocats"
    end

    test "403 pour un user non-membre de la résidence", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      stranger = insert_user!()

      conn = conn |> authed(stranger) |> get(~p"/api/v1/residences/#{residence.id}/contacts")

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/residences/:rid/contacts" do
    test "président CS peut créer un contact", %{conn: conn} do
      {residence, _b, _m, president} = setup_residence_with_member_and_president()

      conn =
        conn
        |> authed(president)
        |> post(~p"/api/v1/residences/#{residence.id}/contacts", %{
          "contact" => %{
            "name" => "Cabinet LAMY",
            "kind" => "legal_entity",
            "title" => "Syndic alternatif",
            "email" => "contact@lamy.fr",
            "address" => "12 rue de la Paix\n75002 Paris"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "Cabinet LAMY"
      assert data["kind"] == "legal_entity"
      assert data["title"] == "Syndic alternatif"
      assert data["email"] == "contact@lamy.fr"
      assert data["created_by"]["id"] == president.id
    end

    test "copropriétaire lambda → 403", %{conn: conn} do
      {residence, _b, member, _p} = setup_residence_with_member_and_president()

      conn =
        conn
        |> authed(member)
        |> post(~p"/api/v1/residences/#{residence.id}/contacts", %{
          "contact" => %{"name" => "Ne devrait pas passer"}
        })

      assert json_response(conn, 403)
    end

    test "super_admin global peut créer même sans être membre", %{conn: conn} do
      residence = insert_residence!()
      _ = insert_building!(residence)
      admin = insert_user!(:super_admin)

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/residences/#{residence.id}/contacts", %{
          "contact" => %{"name" => "Cabinet Foncia"}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["name"] == "Cabinet Foncia"
    end

    test "422 si le nom est vide", %{conn: conn} do
      {residence, _b, _m, president} = setup_residence_with_member_and_president()

      conn =
        conn
        |> authed(president)
        |> post(~p"/api/v1/residences/#{residence.id}/contacts", %{
          "contact" => %{"name" => ""}
        })

      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end

    test "422 si l'email est mal formé", %{conn: conn} do
      {residence, _b, _m, president} = setup_residence_with_member_and_president()

      conn =
        conn
        |> authed(president)
        |> post(~p"/api/v1/residences/#{residence.id}/contacts", %{
          "contact" => %{"name" => "Maître X", "email" => "pas-un-email"}
        })

      assert %{"errors" => %{"email" => _}} = json_response(conn, 422)
    end

    test "email vide accepté (champ optionnel, blanchi en nil)", %{conn: conn} do
      {residence, _b, _m, president} = setup_residence_with_member_and_president()

      conn =
        conn
        |> authed(president)
        |> post(~p"/api/v1/residences/#{residence.id}/contacts", %{
          "contact" => %{"name" => "Mairie", "email" => ""}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert is_nil(data["email"])
    end
  end

  describe "PATCH /api/v1/residences/:rid/contacts/:id" do
    test "président CS peut éditer un contact existant", %{conn: conn} do
      {residence, _b, _m, president} = setup_residence_with_member_and_president()
      {:ok, c} = Contacts.create_contact(residence.id, president.id, %{"name" => "Old name"})

      conn =
        conn
        |> authed(president)
        |> patch(~p"/api/v1/residences/#{residence.id}/contacts/#{c.id}", %{
          "contact" => %{"name" => "New name", "phone" => "01 23 45 67 89"}
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "New name"
      assert data["phone"] == "01 23 45 67 89"
    end

    test "copro lambda → 403 sur l'édition", %{conn: conn} do
      {residence, _b, member, president} = setup_residence_with_member_and_president()
      {:ok, c} = Contacts.create_contact(residence.id, president.id, %{"name" => "Cabinet LAMY"})

      conn =
        conn
        |> authed(member)
        |> patch(~p"/api/v1/residences/#{residence.id}/contacts/#{c.id}", %{
          "contact" => %{"name" => "Pirate"}
        })

      assert json_response(conn, 403)
    end

    test "404 si l'id n'appartient pas à la résidence (même si user privilégié)", %{conn: conn} do
      {residence_a, _ba, _ma, president_a} = setup_residence_with_member_and_president()

      residence_b = insert_residence!()
      building_b = insert_building!(residence_b)
      president_b = insert_user!()
      {:ok, _} = Buildings.add_member(building_b.id, president_b.id, :president_cs)
      {:ok, contact_b} = Contacts.create_contact(residence_b.id, president_b.id, %{"name" => "X"})

      # Le président de la résidence A tente de toucher au contact de B
      # via une URL forgée pointant sur la résidence A.
      conn =
        conn
        |> authed(president_a)
        |> patch(~p"/api/v1/residences/#{residence_a.id}/contacts/#{contact_b.id}", %{
          "contact" => %{"name" => "Pirate"}
        })

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/v1/residences/:rid/contacts/:id" do
    test "président CS peut supprimer", %{conn: conn} do
      {residence, _b, _m, president} = setup_residence_with_member_and_president()
      {:ok, c} = Contacts.create_contact(residence.id, president.id, %{"name" => "À jeter"})

      conn =
        conn
        |> authed(president)
        |> delete(~p"/api/v1/residences/#{residence.id}/contacts/#{c.id}")

      assert response(conn, 204) == ""
      assert Contacts.list_residence_contacts(residence.id) == []
    end

    test "copro lambda → 403 sur la suppression", %{conn: conn} do
      {residence, _b, member, president} = setup_residence_with_member_and_president()
      {:ok, c} = Contacts.create_contact(residence.id, president.id, %{"name" => "À garder"})

      conn =
        conn
        |> authed(member)
        |> delete(~p"/api/v1/residences/#{residence.id}/contacts/#{c.id}")

      assert json_response(conn, 403)
      assert length(Contacts.list_residence_contacts(residence.id)) == 1
    end
  end
end
