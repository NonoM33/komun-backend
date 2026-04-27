defmodule KomunBackendWeb.IncidentControllerTest do
  @moduledoc """
  Tests de non-divulgation pour les endpoints `/api/v1/buildings/:bid/incidents`.

  Le focus est la garantie produit : "ton nom n'apparaît nulle part" pour
  un signalement `:council_only`. Cela couvre :

  1. La sérialisation JSON :
     - `reporter` est toujours `nil`, même quand le viewer est l'auteur,
       même quand le viewer est `:membre_cs` du conseil.
     - `location` et `lot_number` sont masqués (peuvent identifier
       indirectement l'auteur).
     - **Aucun champ JSON ne contient l'UUID du `reporter_id`** — scan
       structurel défensif pour bloquer une régression où un futur dev
       ajouterait innocemment `reporter_id`, `assignee_id`, ou un
       `confirmed_by_id` qui pointerait l'auteur.
     - `viewer_is_reporter` est `true` ssi le viewer est l'auteur.

  2. Les endpoints :
     - GET `/:id` retourne 404 à un coproprio tiers sur un `:council_only`.
     - GET `/:id` retourne 200 au créateur sur son propre `:council_only`
       (nouveau — avant, le créateur perdait la main sur sa data).
     - GET `/:id` retourne 200 à un `:membre_cs`.
     - GET `/` ne contient pas les `:council_only` des autres.
     - GET `/` contient les `:council_only` du créateur.
     - PUT `/:id` retourne 404 au créateur sur son propre `:council_only`
       (lecture autorisée, écriture interdite — c'est le rôle du conseil).

  Ces tests gèlent la promesse "anonymat protégé contre les représailles".
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Incidents.Incident
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

  defp insert_incident!(building, reporter, attrs \\ %{}) do
    defaults = %{
      title: "Tensions de voisinage",
      description: "Bruits récurrents la nuit, je préfère ne pas être identifié.",
      category: :autre,
      severity: :medium,
      visibility: :standard,
      location: "Cage A — 3e étage",
      lot_number: "12B",
      building_id: building.id,
      reporter_id: reporter.id
    }

    %Incident{}
    |> Incident.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # Setup partagé : un bâtiment, son auteur (coproprio simple), un
  # bystander coproprio tiers, un :membre_cs du conseil, et deux incidents
  # (un :standard et un :council_only).
  defp setup_full!() do
    residence = insert_residence!()
    building = insert_building!(residence)

    reporter = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, reporter.id, :coproprietaire)

    bystander = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, bystander.id, :coproprietaire)

    cs_member = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, cs_member.id, :membre_cs)

    confidential =
      insert_incident!(building, reporter, %{
        visibility: :council_only,
        title: "Signalement confidentiel"
      })

    standard =
      insert_incident!(building, reporter, %{
        visibility: :standard,
        title: "Signalement standard"
      })

    %{
      building: building,
      reporter: reporter,
      bystander: bystander,
      cs_member: cs_member,
      confidential: confidential,
      standard: standard
    }
  end

  # Scan profond du payload JSON : retourne tous les leaves (string) qui
  # contiennent l'UUID donné, en remontant le chemin clé/clé/clé… afin
  # qu'une régression renvoie un message diagnostique exploitable.
  defp deep_search_uuid(payload, uuid, path \\ []) do
    case payload do
      m when is_map(m) ->
        Enum.flat_map(m, fn {k, v} -> deep_search_uuid(v, uuid, path ++ [k]) end)

      l when is_list(l) ->
        l
        |> Enum.with_index()
        |> Enum.flat_map(fn {v, i} -> deep_search_uuid(v, uuid, path ++ [i]) end)

      s when is_binary(s) ->
        if s == uuid, do: [Enum.join(Enum.map(path, &to_string/1), ".")], else: []

      _ ->
        []
    end
  end

  describe "GET /buildings/:b/incidents/:id — :council_only" do
    test "retourne 200 au créateur sur son propre :council_only", %{conn: conn} do
      ctx = setup_full!()

      conn =
        conn
        |> authed(ctx.reporter)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == ctx.confidential.id
      assert body["data"]["viewer_is_reporter"] == true
    end

    test "retourne 200 à un :membre_cs sur n'importe quel :council_only", %{conn: conn} do
      ctx = setup_full!()

      conn =
        conn
        |> authed(ctx.cs_member)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == ctx.confidential.id
      assert body["data"]["viewer_is_reporter"] == false
      assert body["data"]["viewer_privileged"] == true
    end

    test "retourne 404 à un coproprio tiers sur un :council_only", %{conn: conn} do
      ctx = setup_full!()

      conn =
        conn
        |> authed(ctx.bystander)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")

      assert json_response(conn, 404)
    end

    test "retourne 200 à un coproprio tiers sur un :standard", %{conn: conn} do
      ctx = setup_full!()

      conn =
        conn
        |> authed(ctx.bystander)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.standard.id}")

      assert json_response(conn, 200)
    end
  end

  describe "GET /buildings/:b/incidents/:id — sérialisation JSON :council_only" do
    test "reporter == nil même quand le viewer EST le créateur", %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.reporter)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")
        |> json_response(200)

      # Le reporter ne se "voit" pas dans le payload — c'est l'invariant
      # qui rend la promesse vérifiable simplement : "ton nom n'apparaît
      # nulle part" inclut TON propre payload.
      assert is_nil(body["data"]["reporter"])
      # Mais on lui dit que c'est lui via un flag dérivé :
      assert body["data"]["viewer_is_reporter"] == true
    end

    test "reporter == nil même quand le viewer est :membre_cs", %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.cs_member)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")
        |> json_response(200)

      assert is_nil(body["data"]["reporter"])
      assert body["data"]["viewer_is_reporter"] == false
    end

    test "location et lot_number sont nuls sur :council_only (peuvent identifier indirectement)",
         %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.cs_member)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")
        |> json_response(200)

      assert is_nil(body["data"]["location"])
      assert is_nil(body["data"]["lot_number"])
    end

    test "scan structurel : aucun champ JSON ne contient l'UUID du reporter sur :council_only",
         %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.cs_member)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")
        |> json_response(200)

      leaks = deep_search_uuid(body["data"], ctx.reporter.id)

      assert leaks == [],
             "Le payload :council_only ne doit JAMAIS contenir l'UUID du reporter. Trouvé dans : #{inspect(leaks)}"
    end

    test "même scan, mais quand le viewer EST le créateur — l'UUID ne fuite pas non plus",
         %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.reporter)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}")
        |> json_response(200)

      leaks = deep_search_uuid(body["data"], ctx.reporter.id)

      assert leaks == [],
             "Même au créateur, le payload ne doit pas exposer son UUID — `viewer_is_reporter` suffit pour différencier l'UI."
    end

    test "sur un :standard, le reporter EST sérialisé normalement", %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.cs_member)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.standard.id}")
        |> json_response(200)

      # Sanity check : le masquage est bien limité à :council_only,
      # on ne brise pas le cas standard.
      assert body["data"]["reporter"]["id"] == ctx.reporter.id
      assert body["data"]["location"] == "Cage A — 3e étage"
    end
  end

  describe "GET /buildings/:b/incidents — liste" do
    test "ne contient pas les :council_only des autres pour un coproprio tiers", %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.bystander)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents")
        |> json_response(200)

      ids = Enum.map(body["data"], & &1["id"])
      assert ctx.standard.id in ids
      refute ctx.confidential.id in ids
    end

    test "contient les :council_only du créateur (lui-même)", %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.reporter)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents")
        |> json_response(200)

      ids = Enum.map(body["data"], & &1["id"])
      assert ctx.standard.id in ids
      assert ctx.confidential.id in ids,
             "Le créateur doit retrouver son signalement confidentiel dans la liste — sinon il perd la main sur sa data."
    end

    test "viewer_is_reporter dans la liste reflète bien le viewer", %{conn: conn} do
      ctx = setup_full!()

      body =
        conn
        |> authed(ctx.reporter)
        |> get(~p"/api/v1/buildings/#{ctx.building.id}/incidents")
        |> json_response(200)

      for incident <- body["data"] do
        # Tous les incidents listés ici ont été créés par `reporter`,
        # donc viewer_is_reporter est true.
        assert incident["viewer_is_reporter"] == true
      end
    end
  end

  describe "PUT /buildings/:b/incidents/:id — :council_only" do
    test "retourne 404 au créateur non-privilégié sur son propre :council_only (lecture OK, écriture interdite)",
         %{conn: conn} do
      ctx = setup_full!()

      conn =
        conn
        |> authed(ctx.reporter)
        |> put(
          ~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}",
          %{"incident" => %{"status" => "in_progress"}}
        )

      assert json_response(conn, 404),
             "Modifier le statut d'un :council_only est réservé au conseil — même son auteur ne le peut pas."
    end

    test "un :membre_cs peut modifier un :council_only", %{conn: conn} do
      ctx = setup_full!()

      conn =
        conn
        |> authed(ctx.cs_member)
        |> put(
          ~p"/api/v1/buildings/#{ctx.building.id}/incidents/#{ctx.confidential.id}",
          %{"incident" => %{"status" => "in_progress"}}
        )

      body = json_response(conn, 200)
      assert body["data"]["status"] == "in_progress"
      # Re-vérification : la sérialisation reste safe après update.
      assert is_nil(body["data"]["reporter"])
    end
  end

  describe "POST /buildings/:b/incidents — création :council_only" do
    test "le créateur reçoit son incident avec viewer_is_reporter=true et reporter=nil",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      reporter = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, reporter.id, :coproprietaire)

      conn =
        conn
        |> authed(reporter)
        |> post(~p"/api/v1/buildings/#{building.id}/incidents", %{
          "incident" => %{
            "title" => "Tensions sensibles",
            "description" => "Sujet délicat, je préfère rester anonyme.",
            "category" => "autre",
            "visibility" => "council_only"
          }
        })

      body = json_response(conn, 201)
      assert body["data"]["visibility"] == "council_only"
      assert body["data"]["viewer_is_reporter"] == true
      assert is_nil(body["data"]["reporter"])
      # `viewer_privileged` reflète juste le rôle, pas le fait d'être l'auteur :
      # un coproprio créateur n'est PAS un viewer privilégié.
      assert body["data"]["viewer_privileged"] == false
    end
  end
end
