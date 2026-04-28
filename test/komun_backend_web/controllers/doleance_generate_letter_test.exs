defmodule KomunBackendWeb.DoleanceGenerateLetterTest do
  @moduledoc """
  Tests focalisés sur le payload optionnel de
  `POST /api/v1/buildings/:bid/doleances/:doleance_id/generate-letter`.

  L'IA n'est pas appelée en environnement test (GROQ_API_KEY absent →
  503), mais la persistance du destinataire (`target_*`) doit avoir lieu
  AVANT l'appel IA. Donc même un 503 doit laisser la doléance enrichie
  des champs envoyés dans le body.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Buildings, Doleances, Repo, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Doleances.Doleance
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
      address: "12 rue de la Paix",
      city: "Paris",
      postal_code: "75002",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_user!(role \\ :coproprietaire) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role,
      first_name: "Pascale",
      last_name: "Michon"
    })
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_author do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :membre_cs)

    {:ok, doleance} =
      Doleances.create_doleance(building.id, user.id, %{
        "title" => "Traces d'enduit dans le hall",
        "description" => "Résidus visibles depuis le 2 mars 2026.",
        "category" => "parties_communes"
      })

    {building, user, doleance}
  end

  describe "POST /generate-letter — persistance du destinataire" do
    test "persiste target_name, target_email et target_address fournis dans le body", %{conn: conn} do
      {building, user, doleance} = setup_author()

      payload = %{
        "author_first_name" => "Pascale",
        "author_last_name" => "Michon",
        "author_role_label" => "Membre du conseil syndical",
        "target_name" => "Cabinet Foncia / Mme Bréard",
        "target_email" => "contact@foncia.fr",
        "target_address" => "15-17 route d'Antony\n91320 Wissous"
      }

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/doleances/#{doleance.id}/generate-letter", payload)

      # GROQ_API_KEY absent → l'IA renvoie :no_ai_key → 503.
      assert conn.status == 503

      reloaded = Repo.get!(Doleance, doleance.id)
      assert reloaded.target_name == "Cabinet Foncia / Mme Bréard"
      assert reloaded.target_email == "contact@foncia.fr"
      assert reloaded.target_address == "15-17 route d'Antony\n91320 Wissous"
    end

    test "trim les whitespace et ignore les chaînes vides", %{conn: conn} do
      {building, user, doleance} = setup_author()

      payload = %{
        "target_name" => "  Foncia  ",
        "target_email" => "",
        "target_address" => "  "
      }

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/doleances/#{doleance.id}/generate-letter", payload)

      assert conn.status == 503

      reloaded = Repo.get!(Doleance, doleance.id)
      assert reloaded.target_name == "Foncia"
      assert reloaded.target_email == nil
      assert reloaded.target_address == nil
    end

    test "n'écrase pas les champs existants quand le body est vide", %{conn: conn} do
      {building, user, doleance} = setup_author()

      {:ok, _} =
        Doleances.update_doleance(doleance, %{
          "target_name" => "Foncia historique",
          "target_email" => "old@foncia.fr"
        })

      conn =
        conn
        |> authed(user)
        |> post(~p"/api/v1/buildings/#{building.id}/doleances/#{doleance.id}/generate-letter", %{})

      assert conn.status == 503

      reloaded = Repo.get!(Doleance, doleance.id)
      assert reloaded.target_name == "Foncia historique"
      assert reloaded.target_email == "old@foncia.fr"
    end

    test "renvoie target_address dans la réponse JSON", %{conn: conn} do
      {building, user, doleance} = setup_author()

      {:ok, _} =
        Doleances.update_doleance(doleance, %{
          "target_address" => "1 place Vendôme\n75001 Paris"
        })

      conn =
        conn
        |> authed(user)
        |> get(~p"/api/v1/buildings/#{building.id}/doleances/#{doleance.id}")

      assert %{"data" => %{"target_address" => "1 place Vendôme\n75001 Paris"}} =
               json_response(conn, 200)
    end
  end
end
