defmodule KomunBackendWeb.IncidentCasesControllerTest do
  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Incidents, Repo, Residences}
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
      email: "u#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp insert_member!(building, user, role) do
    {:ok, _m} = Buildings.add_member(building.id, user.id, role)
    :ok
  end

  defp insert_incident!(building, reporter, attrs \\ %{}) do
    base = %{
      "title" => "Incident #{System.unique_integer([:positive])}",
      "description" => "Description suffisamment longue pour valider.",
      "category" => "serrurerie"
    }

    {:ok, i} = Incidents.create_incident(building.id, reporter.id, Map.merge(base, attrs))
    i
  end

  defp authed_conn(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    conn |> put_req_header("authorization", "Bearer #{token}")
  end

  describe "GET /buildings/:id/incidents/cases" do
    test "renvoie les dossiers ouverts avec metrics et meta.can_follow_up", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      cs = insert_user!()
      insert_member!(building, cs, :membre_cs)

      _open_inc = insert_incident!(building, reporter)

      body =
        conn
        |> authed_conn(cs)
        |> get("/api/v1/buildings/#{building.id}/incidents/cases")
        |> json_response(200)

      assert is_list(body["data"])
      assert length(body["data"]) == 1
      [case_payload] = body["data"]

      assert case_payload["metrics"]["days_open"] >= 0
      assert case_payload["follow_up_count"] == 0
      assert case_payload["last_event"]["event_type"] == "created"

      # Le conseil peut relancer
      assert body["meta"]["can_follow_up"] == true
      assert body["meta"]["viewer_privileged"] == true
    end

    test "un coproprietaire simple ne peut pas relancer (meta.can_follow_up=false)", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      body =
        conn
        |> authed_conn(reporter)
        |> get("/api/v1/buildings/#{building.id}/incidents/cases")
        |> json_response(200)

      assert body["meta"]["can_follow_up"] == false
      assert body["meta"]["viewer_privileged"] == false
    end

    test "403 pour un user non membre du bâtiment", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      stranger = insert_user!()

      assert conn
             |> authed_conn(stranger)
             |> get("/api/v1/buildings/#{building.id}/incidents/cases")
             |> json_response(403)
    end
  end

  describe "POST /buildings/:id/incidents/:id/follow-ups" do
    test "le conseil syndical peut relancer (201) et l'event est retourné", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      cs = insert_user!()
      insert_member!(building, cs, :membre_cs)

      incident = insert_incident!(building, reporter)

      body =
        conn
        |> authed_conn(cs)
        |> post(
          "/api/v1/buildings/#{building.id}/incidents/#{incident.id}/follow-ups",
          %{"message" => "On en est où sur ce dossier ?"}
        )
        |> json_response(201)

      assert body["data"]["event_type"] == "follow_up"
      assert body["data"]["payload"]["message"] =~ "où"
      assert body["data"]["actor"]["id"] == cs.id
    end

    test "un coproprietaire simple → 403", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)

      incident = insert_incident!(building, reporter)

      body =
        conn
        |> authed_conn(reporter)
        |> post(
          "/api/v1/buildings/#{building.id}/incidents/#{incident.id}/follow-ups",
          %{"message" => "Quand est-ce qu'on règle ça ?"}
        )
        |> json_response(403)

      assert body["error"] =~ "conseil"
    end

    test "message trop court → 422", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)

      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      cs = insert_user!()
      insert_member!(building, cs, :membre_cs)

      incident = insert_incident!(building, reporter)

      assert conn
             |> authed_conn(cs)
             |> post(
               "/api/v1/buildings/#{building.id}/incidents/#{incident.id}/follow-ups",
               %{"message" => "court"}
             )
             |> json_response(422)
    end
  end

  describe "GET /buildings/:id/incidents/:id/events" do
    test "liste la timeline triée", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      reporter = insert_user!()
      insert_member!(building, reporter, :coproprietaire)
      incident = insert_incident!(building, reporter)

      body =
        conn
        |> authed_conn(reporter)
        |> get("/api/v1/buildings/#{building.id}/incidents/#{incident.id}/events")
        |> json_response(200)

      events = body["data"]
      assert hd(events)["event_type"] == "created"
    end
  end
end
