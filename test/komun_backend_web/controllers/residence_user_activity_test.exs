defmodule KomunBackendWeb.ResidenceUserActivityTest do
  @moduledoc """
  Tests des endpoints `GET /api/v1/residences/:rid/users/:uid/incidents`
  et `…/doleances` — la fiche détaillée d'un voisin (côté front) consulte
  ces routes pour afficher l'activité d'un copropriétaire / locataire sur
  l'ensemble de la résidence (pas seulement sur le bâtiment courant du
  viewer).

  Couvre :
    1. Happy path — un membre du conseil voit les incidents et doléances
       d'un voisin sur tous les bâtiments de la résidence.
    2. Confidentialité — un incident `:council_only` n'apparaît PAS dans
       la liste vue par un tiers, même privilégié (sinon le filtre par
       reporter_id le révèle implicitement).
    3. Self-view — un user voit ses propres council_only.
    4. Forbidden — un copropriétaire lambda qui essaie de consulter
       l'activité d'un autre voisin reçoit 403.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Doleances, Incidents, Repo, Residences}
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

  defp create_incident!(building, reporter, attrs \\ %{}) do
    {:ok, inc} =
      Incidents.create_incident(building.id, reporter.id, %{
        "title" => attrs[:title] || "Fuite d'eau",
        "description" => attrs[:description] || "Plafond qui dégouline",
        "category" => attrs[:category] || "plomberie",
        "visibility" => attrs[:visibility] || :standard
      })

    inc
  end

  defp create_doleance!(building, author, attrs \\ %{}) do
    {:ok, d} =
      Doleances.create_doleance(building.id, author.id, %{
        "title" => attrs[:title] || "Rampe de parking trop pentue",
        "description" => attrs[:description] || "Voitures basses qui frottent",
        "category" => attrs[:category] || "voirie_parking"
      })

    d
  end

  describe "GET /api/v1/residences/:rid/users/:uid/incidents" do
    test "membre du CS voit les incidents d'un voisin sur toute la résidence", %{conn: conn} do
      residence = insert_residence!()
      b1 = insert_building!(residence)
      b2 = insert_building!(residence)

      reporter = insert_user!()
      cs = insert_user!()

      {:ok, _} = Buildings.add_member(b1.id, reporter.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b2.id, reporter.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b1.id, cs.id, :membre_cs)

      # Un incident dans chaque bâtiment, même reporter
      i1 = create_incident!(b1, reporter, %{title: "Plomberie B1"})
      i2 = create_incident!(b2, reporter, %{title: "Ascenseur B2"})
      # Un incident d'un autre voisin — ne doit PAS apparaître
      other = insert_user!()
      {:ok, _} = Buildings.add_member(b1.id, other.id, :coproprietaire)
      _other_inc = create_incident!(b1, other, %{title: "Pas pour ce voisin"})

      body =
        conn
        |> authed(cs)
        |> get(~p"/api/v1/residences/#{residence.id}/users/#{reporter.id}/incidents")
        |> json_response(200)

      titles = body["data"] |> Enum.map(& &1["title"]) |> Enum.sort()
      assert titles == [i1.title, i2.title] |> Enum.sort()
    end

    test "incident :council_only n'apparaît PAS dans la liste d'un tiers privilégié",
         %{conn: conn} do
      residence = insert_residence!()
      b = insert_building!(residence)
      reporter = insert_user!()
      cs = insert_user!()

      {:ok, _} = Buildings.add_member(b.id, reporter.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b.id, cs.id, :membre_cs)

      # Un public, un confidentiel
      _pub = create_incident!(b, reporter, %{title: "Visible"})
      _confid = create_incident!(b, reporter, %{title: "Confidentiel", visibility: :council_only})

      body =
        conn
        |> authed(cs)
        |> get(~p"/api/v1/residences/#{residence.id}/users/#{reporter.id}/incidents")
        |> json_response(200)

      assert Enum.map(body["data"], & &1["title"]) == ["Visible"]
    end

    test "self-view : l'utilisateur voit ses propres incidents :council_only", %{conn: conn} do
      residence = insert_residence!()
      b = insert_building!(residence)
      reporter = insert_user!()
      {:ok, _} = Buildings.add_member(b.id, reporter.id, :coproprietaire)

      _pub = create_incident!(b, reporter, %{title: "Public"})
      _confid = create_incident!(b, reporter, %{title: "Mon confidentiel", visibility: :council_only})

      body =
        conn
        |> authed(reporter)
        |> get(~p"/api/v1/residences/#{residence.id}/users/#{reporter.id}/incidents")
        |> json_response(200)

      assert Enum.sort(Enum.map(body["data"], & &1["title"])) == ["Mon confidentiel", "Public"]
    end

    test "copropriétaire lambda → 403 quand il consulte un autre voisin", %{conn: conn} do
      residence = insert_residence!()
      b = insert_building!(residence)
      reporter = insert_user!()
      lambda = insert_user!()

      {:ok, _} = Buildings.add_member(b.id, reporter.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b.id, lambda.id, :coproprietaire)

      _ = create_incident!(b, reporter)

      conn
      |> authed(lambda)
      |> get(~p"/api/v1/residences/#{residence.id}/users/#{reporter.id}/incidents")
      |> json_response(403)
    end

    test "résidence inexistante → 404", %{conn: conn} do
      cs = insert_user!()
      target = insert_user!()
      fake = "00000000-0000-0000-0000-000000000999"

      conn
      |> authed(cs)
      |> get(~p"/api/v1/residences/#{fake}/users/#{target.id}/incidents")
      |> json_response(404)
    end
  end

  describe "GET /api/v1/residences/:rid/users/:uid/doleances" do
    test "membre du CS voit les doléances d'un voisin sur toute la résidence", %{conn: conn} do
      residence = insert_residence!()
      b1 = insert_building!(residence)
      b2 = insert_building!(residence)

      author = insert_user!()
      cs = insert_user!()

      {:ok, _} = Buildings.add_member(b1.id, author.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b2.id, author.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b1.id, cs.id, :membre_cs)

      d1 = create_doleance!(b1, author, %{title: "Doléance B1"})
      d2 = create_doleance!(b2, author, %{title: "Doléance B2"})

      body =
        conn
        |> authed(cs)
        |> get(~p"/api/v1/residences/#{residence.id}/users/#{author.id}/doleances")
        |> json_response(200)

      titles = body["data"] |> Enum.map(& &1["title"]) |> Enum.sort()
      assert titles == Enum.sort([d1.title, d2.title])
    end

    test "copropriétaire lambda → 403 quand il consulte un autre voisin", %{conn: conn} do
      residence = insert_residence!()
      b = insert_building!(residence)
      author = insert_user!()
      lambda = insert_user!()

      {:ok, _} = Buildings.add_member(b.id, author.id, :coproprietaire)
      {:ok, _} = Buildings.add_member(b.id, lambda.id, :coproprietaire)

      _ = create_doleance!(b, author)

      conn
      |> authed(lambda)
      |> get(~p"/api/v1/residences/#{residence.id}/users/#{author.id}/doleances")
      |> json_response(403)
    end
  end
end
