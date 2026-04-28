defmodule KomunBackendWeb.ImprovementTicketControllerTest do
  @moduledoc """
  Tickets de feedback produit. Couverture minimale :

  - création par un utilisateur authentifié
  - liste réservée à l'auteur (un autre utilisateur ne voit pas mes tickets)
  - lecture détaillée : auteur OK, autre user 403, super_admin OK
  - admin route : index / patch (super_admin uniquement)
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian

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

  defp create_ticket!(author, attrs \\ %{}) do
    {:ok, t} =
      KomunBackend.ImprovementTickets.create_ticket(
        author.id,
        Map.merge(
          %{
            "kind" => "bug",
            "title" => "Mon ticket de test",
            "description" => "Description longue assez correcte"
          },
          attrs
        )
      )

    t
  end

  describe "POST /api/v1/improvement_tickets" do
    test "un utilisateur connecté crée un ticket", %{conn: conn} do
      user = insert_user!()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/improvement_tickets", %{
          "ticket" => %{
            "kind" => "bug",
            "title" => "La page Votes plante",
            "description" => "Au chargement, écran blanc et console rouge."
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["kind"] == "bug"
      assert data["status"] == "open"
      assert data["author"]["id"] == user.id
      assert data["title"] == "La page Votes plante"
    end

    test "rejette un payload invalide (titre trop court)", %{conn: conn} do
      user = insert_user!()

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/improvement_tickets", %{
          "ticket" => %{
            "kind" => "bug",
            "title" => "x",
            "description" => "ok ok ok"
          }
        })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "title")
    end

    test "rejette un appel non authentifié", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/improvement_tickets", %{
          "ticket" => %{
            "kind" => "bug",
            "title" => "ok ok ok ok",
            "description" => "ok ok ok ok ok"
          }
        })

      assert response(conn, 401)
    end
  end

  describe "GET /api/v1/improvement_tickets" do
    test "liste uniquement les tickets de l'auteur courant", %{conn: conn} do
      alice = insert_user!()
      bob = insert_user!()

      _alice_t = create_ticket!(alice, %{"title" => "Ticket Alice 1"})
      _alice_t2 = create_ticket!(alice, %{"title" => "Ticket Alice 2"})
      _bob_t = create_ticket!(bob, %{"title" => "Ticket Bob"})

      conn =
        conn
        |> authed(alice)
        |> get(~p"/api/v1/improvement_tickets")

      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 2

      titles = Enum.map(data, & &1["title"]) |> Enum.sort()
      assert titles == ["Ticket Alice 1", "Ticket Alice 2"]
    end
  end

  describe "GET /api/v1/improvement_tickets/:id" do
    test "l'auteur peut lire son ticket", %{conn: conn} do
      alice = insert_user!()
      ticket = create_ticket!(alice)

      conn =
        conn
        |> authed(alice)
        |> get(~p"/api/v1/improvement_tickets/#{ticket.id}")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == ticket.id
    end

    test "un autre utilisateur reçoit 403", %{conn: conn} do
      alice = insert_user!()
      mallory = insert_user!()
      ticket = create_ticket!(alice)

      conn =
        conn
        |> authed(mallory)
        |> get(~p"/api/v1/improvement_tickets/#{ticket.id}")

      assert response(conn, 403)
    end

    test "un super_admin peut lire le ticket d'un autre user", %{conn: conn} do
      alice = insert_user!()
      admin = insert_user!(:super_admin)
      ticket = create_ticket!(alice)

      conn =
        conn
        |> authed(admin)
        |> get(~p"/api/v1/improvement_tickets/#{ticket.id}")

      assert %{"data" => %{"id" => _}} = json_response(conn, 200)
    end
  end

  describe "Admin routes" do
    test "GET /admin/improvement_tickets liste tous les tickets", %{conn: conn} do
      alice = insert_user!()
      bob = insert_user!()
      admin = insert_user!(:super_admin)

      _ = create_ticket!(alice, %{"title" => "Ticket Alice"})
      _ = create_ticket!(bob, %{"title" => "Ticket Bob"})

      conn =
        conn
        |> authed(admin)
        |> get(~p"/api/v1/admin/improvement_tickets")

      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 2
    end

    test "GET /admin/improvement_tickets retourne 403 sans super_admin", %{conn: conn} do
      user = insert_user!()
      conn = conn |> authed(user) |> get(~p"/api/v1/admin/improvement_tickets")
      assert response(conn, 403)
    end

    test "PATCH /admin/improvement_tickets/:id change le statut", %{conn: conn} do
      alice = insert_user!()
      admin = insert_user!(:super_admin)
      ticket = create_ticket!(alice)

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/v1/admin/improvement_tickets/#{ticket.id}", %{
          "ticket" => %{"status" => "resolved", "admin_note" => "Corrigé en 2026.18.20"}
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "resolved"
      assert data["admin_note"] == "Corrigé en 2026.18.20"
      assert data["resolved_at"] != nil
    end

    test "PATCH /admin/improvement_tickets/:id refuse un user non-admin", %{conn: conn} do
      alice = insert_user!()
      mallory = insert_user!()
      ticket = create_ticket!(alice)

      conn =
        conn
        |> authed(mallory)
        |> patch(~p"/api/v1/admin/improvement_tickets/#{ticket.id}", %{
          "ticket" => %{"status" => "resolved"}
        })

      assert response(conn, 403)
    end
  end
end
