defmodule KomunBackendWeb.DiligenceControllerTest do
  @moduledoc """
  Tests des endpoints `/api/v1/buildings/:bid/diligences`. Le focus
  principal est la **sécurité** : seuls les rôles privilégiés
  (super_admin, syndic_*, president_cs, membre_cs) doivent pouvoir
  lire/écrire des diligences. Tout autre rôle (copropriétaire,
  locataire, non-membre) doit recevoir 403 / 404.
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

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_with_president do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)
    {building, user}
  end

  describe "GET /api/v1/buildings/:bid/diligences" do
    test "liste vide pour un bâtiment sans diligence", %{conn: conn} do
      {building, user} = setup_with_president()

      conn =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}/diligences")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "renvoie 403 à un copropriétaire standard", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      conn =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}/diligences")

      assert json_response(conn, 403)
    end

    test "renvoie 403 à un user non-membre du bâtiment", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      stranger = insert_user!()

      conn =
        conn
        |> authed(stranger)
        |> get(~p"/api/v1/buildings/#{building.id}/diligences")

      assert json_response(conn, 403)
    end

    test "autorise un super_admin global même non-membre", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      admin = insert_user!(:super_admin)

      conn =
        conn
        |> authed(admin)
        |> get(~p"/api/v1/buildings/#{building.id}/diligences")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/v1/buildings/:bid/diligences" do
    test "crée une diligence avec ses 9 steps", %{conn: conn} do
      {building, user} = setup_with_president()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences", %{
          "diligence" => %{
            "title" => "Odeurs cannabis lot 14",
            "description" => "Plaintes répétées",
            "source_type" => "copro_owner",
            "source_label" => "M. Untel"
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["title"] == "Odeurs cannabis lot 14"
      assert data["status"] == "open"
      assert length(data["steps"]) == 9

      step_numbers = Enum.map(data["steps"], & &1["step_number"]) |> Enum.sort()
      assert step_numbers == Enum.to_list(1..9)
    end

    test "renvoie 422 si titre trop court", %{conn: conn} do
      {building, user} = setup_with_president()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences", %{
          "diligence" => %{"title" => "abc"}
        })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["title"]
    end

    test "renvoie 403 à un copropriétaire qui tente une création", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      user = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, user.id, :coproprietaire)

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences", %{
          "diligence" => %{"title" => "Tentative interdite"}
        })

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/v1/buildings/:bid/diligences/:id" do
    test "renvoie 404 si on tente d'accéder à une diligence d'un autre bâtiment", %{conn: conn} do
      {building_a, user_a} = setup_with_president()
      {_building_b, _user_b} = setup_with_president()

      # On crée une diligence dans le bâtiment B
      residence_b = insert_residence!()
      building_b = insert_building!(residence_b)
      user_b = insert_user!()
      {:ok, _} = Buildings.add_member(building_b.id, user_b.id, :president_cs)

      {:ok, dilig_b} =
        KomunBackend.Diligences.create_diligence(building_b.id, user_b, %{"title" => "Sujet B"})

      # user_a (président bâtiment A) tente d'accéder via building_a/diligences/dilig_b.id
      conn =
        conn
        |> authed(user_a)
        |> get(~p"/api/v1/buildings/#{building_a.id}/diligences/#{dilig_b.id}")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/buildings/:bid/diligences/:id/steps/:step_number" do
    test "passe un step à completed", %{conn: conn} do
      {building, user} = setup_with_president()

      {:ok, d} =
        KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      conn =
        conn
        |> authed(user)
        |> patch(
          ~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/steps/1",
          %{"step" => %{"status" => "completed", "notes" => "Done"}}
        )

      assert %{"data" => data} = json_response(conn, 200)

      step1 = Enum.find(data["steps"], &(&1["step_number"] == 1))
      assert step1["status"] == "completed"
      assert step1["notes"] == "Done"
      refute is_nil(step1["completed_at"])
    end

    test "renvoie 400 si step_number hors plage", %{conn: conn} do
      {building, user} = setup_with_president()

      {:ok, d} =
        KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      conn =
        conn
        |> authed(user)
        |> patch(
          ~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/steps/99",
          %{"step" => %{"status" => "completed"}}
        )

      assert json_response(conn, 400)
    end
  end

  describe "auth obligatoire" do
    test "GET sans token → 401", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      conn = get(conn, ~p"/api/v1/buildings/#{building.id}/diligences")
      assert response(conn, 401)
    end
  end

  describe "POST /api/v1/buildings/:bid/diligences/:id/files (upload)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "diligence-test-#{System.unique_integer([:positive])}.pdf")
      File.write!(tmp, "%PDF-1.4 fake content for tests")
      on_exit(fn -> File.rm(tmp) end)
      {:ok, tmp: tmp}
    end

    test "attache un PDF à la diligence", %{conn: conn, tmp: tmp} do
      {building, user} = setup_with_president()

      {:ok, d} =
        KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      upload = %Plug.Upload{
        path: tmp,
        filename: "journal.pdf",
        content_type: "application/pdf"
      }

      conn =
        conn
        |> authed(user)
        |> post(
          ~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/files",
          %{"file" => upload, "kind" => "journal", "step_number" => "2"}
        )

      assert %{"data" => data} = json_response(conn, 201)
      assert length(data["files"]) == 1

      [file] = data["files"]
      assert file["kind"] == "journal"
      assert file["step_number"] == 2
      assert file["filename"] == "journal.pdf"
      assert file["mime_type"] == "application/pdf"
      assert file["file_url"] =~ "/uploads/diligences/#{d.id}/"
    end

    test "rejette un mime type non autorisé", %{conn: conn, tmp: tmp} do
      {building, user} = setup_with_president()
      {:ok, d} = KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      upload = %Plug.Upload{
        path: tmp,
        filename: "evil.exe",
        content_type: "application/x-msdownload"
      }

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/files", %{"file" => upload})

      assert %{"error" => err} = json_response(conn, 422)
      assert err =~ "Type de fichier"
    end

    test "rejette une requête sans fichier", %{conn: conn} do
      {building, user} = setup_with_president()
      {:ok, d} = KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/files", %{})

      assert json_response(conn, 422)
    end

    test "renvoie 403 à un copropriétaire", %{conn: conn, tmp: tmp} do
      {building, president} = setup_with_president()
      {:ok, d} = KomunBackend.Diligences.create_diligence(building.id, president, %{"title" => "Sujet test"})

      copro = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, copro.id, :coproprietaire)

      upload = %Plug.Upload{
        path: tmp,
        filename: "ok.pdf",
        content_type: "application/pdf"
      }

      conn =
        conn
        |> authed(copro)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/files", %{"file" => upload})

      assert json_response(conn, 403)
    end
  end

  describe "DELETE /api/v1/buildings/:bid/diligences/:id/files/:fid" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "diligence-test-#{System.unique_integer([:positive])}.pdf")
      File.write!(tmp, "%PDF-1.4 fake")
      on_exit(fn -> File.rm(tmp) end)
      {:ok, tmp: tmp}
    end

    test "supprime un fichier de sa diligence", %{conn: conn, tmp: tmp} do
      {building, user} = setup_with_president()
      {:ok, d} = KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Sujet test"})

      upload = %Plug.Upload{path: tmp, filename: "x.pdf", content_type: "application/pdf"}

      conn1 =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/files", %{"file" => upload})

      [file] = json_response(conn1, 201)["data"]["files"]

      conn2 =
        build_conn()
        |> authed(user)
        |> delete(~p"/api/v1/buildings/#{building.id}/diligences/#{d.id}/files/#{file["id"]}")

      assert response(conn2, 204)
    end

    test "renvoie 404 si on tente de supprimer un fichier d'une autre diligence", %{
      conn: conn,
      tmp: tmp
    } do
      {building, user} = setup_with_president()
      {:ok, d_a} = KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Diligence A"})
      {:ok, d_b} = KomunBackend.Diligences.create_diligence(building.id, user, %{"title" => "Diligence B"})

      upload = %Plug.Upload{path: tmp, filename: "x.pdf", content_type: "application/pdf"}

      conn1 =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/diligences/#{d_a.id}/files", %{"file" => upload})

      [file] = json_response(conn1, 201)["data"]["files"]

      # On tente de supprimer le fichier de d_a via l'URL de d_b → 404
      conn2 =
        build_conn()
        |> authed(user)
        |> delete(~p"/api/v1/buildings/#{building.id}/diligences/#{d_b.id}/files/#{file["id"]}")

      assert json_response(conn2, 404)
    end
  end
end
