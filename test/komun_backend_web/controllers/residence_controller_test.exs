defmodule KomunBackendWeb.ResidenceControllerTest do
  @moduledoc """
  Tests publics de `GET /api/v1/codes/verify` — couvre le cas typique
  d'un code résidence multi-bâtiments avec un placeholder résiduel
  (artefact de l'ancien flow `Buildings.create_building/1` qui auto-
  créait une résidence du même nom). Le placeholder doit disparaître
  du payload pour que l'utilisateur ne voie pas « unissons » dans le
  dropdown bâtiment, à côté de « Bâtiment A » et « Bâtiment B ».
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

  defp insert_residence!(name \\ nil) do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: name || "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence, attrs) do
    base = %{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    }

    %Building{}
    |> Building.initial_changeset(Map.merge(base, attrs))
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

  # ── Authorization scoping (update / delete) ───────────────────────────────
  #
  # Régression : `authorized_for?/2` ne regardait que le rôle GLOBAL de
  # l'user. Un membre / président du conseil syndical (rôle porté par
  # bâtiment) d'une résidence X pouvait donc éditer / supprimer N'IMPORTE
  # quelle résidence, y compris une résidence Y où il n'a aucun mandat.
  # Le fix scope l'autorisation CS à la résidence du bâtiment de l'user.
  describe "authorization scoping — PATCH/DELETE /api/v1/residences/:id" do
    test "CS d'une AUTRE résidence → PATCH = 403", %{conn: conn} do
      residence_x = insert_residence!("Résidence X")
      building_x = insert_building!(residence_x, %{name: "Bât X"})

      residence_y = insert_residence!("Résidence Y")

      # Vecteur exact du bug : l'user porte un rôle CS GLOBAL (User.role
      # = :membre_cs) ET un mandat CS uniquement dans la résidence X.
      # L'ancien `authorized_for?/2` regardait seulement le rôle global →
      # il autorisait l'édition de N'IMPORTE quelle résidence, dont Y.
      cs = insert_user!(:membre_cs)
      {:ok, _} = Buildings.add_member(building_x.id, cs.id, :membre_cs)

      conn
      |> authed(cs)
      |> patch(~p"/api/v1/residences/#{residence_y.id}", %{"name" => "Piraté"})
      |> json_response(403)

      # La résidence Y n'a pas été modifiée.
      assert Repo.get!(Residence, residence_y.id).name == "Résidence Y"
    end

    test "CS d'une AUTRE résidence → DELETE = 403", %{conn: conn} do
      residence_x = insert_residence!("Résidence X del")
      building_x = insert_building!(residence_x, %{name: "Bât X del"})

      residence_y = insert_residence!("Résidence Y del")

      # Rôle CS global + mandat uniquement sur la résidence X (voir note
      # du test PATCH ci-dessus).
      cs = insert_user!(:president_cs)
      {:ok, _} = Buildings.add_member(building_x.id, cs.id, :president_cs)

      conn
      |> authed(cs)
      |> delete(~p"/api/v1/residences/#{residence_y.id}")
      |> json_response(403)

      # Toujours active : la suppression a bien été refusée.
      assert Repo.get!(Residence, residence_y.id).is_active == true
    end

    test "CS de CETTE résidence → PATCH autorisé", %{conn: conn} do
      residence = insert_residence!("Ma copro")
      building = insert_building!(residence, %{name: "Mon bâtiment"})

      cs = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, cs.id, :membre_cs)

      body =
        conn
        |> authed(cs)
        |> patch(~p"/api/v1/residences/#{residence.id}", %{"name" => "Ma copro renommée"})
        |> json_response(200)

      assert body["data"]["name"] == "Ma copro renommée"
      assert Repo.get!(Residence, residence.id).name == "Ma copro renommée"
    end

    test "CS de CETTE résidence → DELETE passe l'authz (pas de 403)", %{conn: conn} do
      residence = insert_residence!("Copro à supprimer")
      building = insert_building!(residence, %{name: "Bât actif"})

      cs = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, cs.id, :president_cs)

      # Le controller refuse ensuite le delete (bâtiment actif restant → 422
      # not_empty), mais l'important ici est que l'authz est passée : ce
      # n'est PAS un 403. C'est exactement ce qui distingue le CS de CETTE
      # résidence d'un CS d'une autre résidence.
      status =
        conn
        |> authed(cs)
        |> delete(~p"/api/v1/residences/#{residence.id}")
        |> Map.fetch!(:status)

      refute status == 403
      assert status == 422
    end

    test "super_admin → PATCH autorisé sur n'importe quelle résidence", %{conn: conn} do
      residence = insert_residence!("Copro admin")
      admin = insert_user!(:super_admin)

      body =
        conn
        |> authed(admin)
        |> patch(~p"/api/v1/residences/#{residence.id}", %{"name" => "Renommé par admin"})
        |> json_response(200)

      assert body["data"]["name"] == "Renommé par admin"
    end

    test "copropriétaire lambda → PATCH = 403", %{conn: conn} do
      residence = insert_residence!("Copro lambda")
      building = insert_building!(residence, %{name: "Bât lambda"})

      lambda = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, lambda.id, :coproprietaire)

      conn
      |> authed(lambda)
      |> patch(~p"/api/v1/residences/#{residence.id}", %{"name" => "Nope"})
      |> json_response(403)
    end
  end

  describe "GET /api/v1/codes/verify (code résidence)" do
    test "cache les bâtiments-placeholder du payload buildings", %{conn: conn} do
      residence = insert_residence!("Unissons")
      _placeholder = insert_building!(residence, %{name: "Unissons", is_placeholder: true})
      real_a = insert_building!(residence, %{name: "Bâtiment A"})
      real_b = insert_building!(residence, %{name: "Bâtiment B"})

      body =
        conn
        |> get(~p"/api/v1/codes/verify?code=#{residence.join_code}")
        |> json_response(200)

      assert body["valid"] == true
      assert body["type"] == "residence"

      returned_ids = body["buildings"] |> Enum.map(& &1["id"]) |> Enum.sort()
      assert returned_ids == Enum.sort([real_a.id, real_b.id])

      returned_names = body["buildings"] |> Enum.map(& &1["name"])
      refute "Unissons" in returned_names
    end

    test "garde le placeholder quand c'est l'unique bâtiment de la résidence", %{conn: conn} do
      # Cas mono-bâtiment : la résidence et son seul bâtiment
      # s'appellent pareil. Si on filtrait, on rendrait une liste vide
      # → le frontend ne saurait sur quoi inscrire l'utilisateur.
      residence = insert_residence!("Solo Copro")
      placeholder = insert_building!(residence, %{name: "Solo Copro", is_placeholder: true})

      body =
        conn
        |> get(~p"/api/v1/codes/verify?code=#{residence.join_code}")
        |> json_response(200)

      assert [item] = body["buildings"]
      assert item["id"] == placeholder.id
      assert item["is_placeholder"] == true
    end

    test "expose is_placeholder sur chaque entrée du payload", %{conn: conn} do
      residence = insert_residence!("Mixed")
      _placeholder = insert_building!(residence, %{name: "Mixed", is_placeholder: true})
      _real = insert_building!(residence, %{name: "Bâtiment Réel"})

      body =
        conn
        |> get(~p"/api/v1/codes/verify?code=#{residence.join_code}")
        |> json_response(200)

      Enum.each(body["buildings"], fn b ->
        assert Map.has_key?(b, "is_placeholder")
      end)
    end
  end

  describe "Buildings.create_building/1 (auto-residence path)" do
    # Mirroir du path controller : les attrs viennent en string keys
    # (params JSON décodés par Plug). `ensure_join_code` et
    # `ensure_residence` partent de cette base.
    test "marque le bâtiment auto-créé comme placeholder" do
      attrs = %{
        "name" => "Mono Building Test",
        "address" => "1 rue Test",
        "city" => "Paris",
        "postal_code" => "75001"
      }

      {:ok, building} = Buildings.create_building(attrs)
      reloaded = Repo.get!(Building, building.id)

      assert reloaded.is_placeholder == true
      assert reloaded.residence_id != nil
    end

    test "ne flag PAS quand residence_id est fourni explicitement" do
      residence = insert_residence!()

      attrs = %{
        "name" => "Bâtiment explicite",
        "address" => "1 rue Test",
        "city" => "Paris",
        "postal_code" => "75001",
        "residence_id" => residence.id
      }

      {:ok, building} = Buildings.create_building(attrs)
      reloaded = Repo.get!(Building, building.id)

      assert reloaded.is_placeholder == false
    end
  end
end
