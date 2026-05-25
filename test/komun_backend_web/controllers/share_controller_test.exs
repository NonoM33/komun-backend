defmodule KomunBackendWeb.ShareControllerTest do
  @moduledoc """
  Couvre les previews Open Graph servies à /share/<resource>/:id —
  c'est ce que voient iMessage, WhatsApp et Slack quand un voisin colle
  un lien Komun dans une conversation. Une preview vide ou cassée
  envoie un message « komun.app — La plateforme qui connecte votre
  copropriété » totalement générique, ce qui fait passer la feature
  pour anonyme et peu engageante.

  Ces tests vérifient que le HTML retourné contient bien les balises
  og:* nécessaires aux scrapers, et que le titre + image correspondent
  à la ressource demandée (pas le fallback générique).
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.{Battles, Buildings, Repo, Residences}
  alias KomunBackend.Accounts.User
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

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  describe "GET /share/battles/:id" do
    test "renvoie un HTML avec og:title = titre de la battle et og:image = photo de la 1ère option",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building.id, creator.id, %{
          "title" => "Choix des brises vues",
          "description" => "On vote ensemble pour le brise-vue du balcon.",
          "options" => [
            %{
              "label" => "Gris clair",
              "attachment_url" => "uploads/votes/brise-vue-gris.png"
            },
            %{"label" => "Beige"},
            %{"label" => "Filet beige"}
          ]
        })

      conn = get(conn, ~p"/share/battles/#{battle.id}")

      assert response = response(conn, 200)
      assert get_resp_header(conn, "content-type") |> List.first() =~ "text/html"

      # Balises og:* obligatoires pour le scraping
      assert response =~ ~s(<meta property="og:title" content="Choix des brises vues" />)
      assert response =~ ~s(<meta property="og:type" content="article" />)
      assert response =~ ~s(<meta property="og:site_name" content="Komun" />)

      # Image = première option avec photo (gris clair). L'URL est
      # absolutisée via BACKEND_PUBLIC_URL.
      assert response =~ "brise-vue-gris.png"

      # Description contient des éléments structurés battle
      assert response =~ "Round 1"
      assert response =~ "option"

      # Twitter card large image (iMessage la consomme aussi)
      assert response =~ ~s(<meta name="twitter:card" content="summary_large_image" />)

      # Redirection humaine vers le SPA
      assert response =~ ~s(<meta http-equiv="refresh")
      assert response =~ "/battles/#{battle.id}"
    end

    test "battle inconnue → fallback générique Komun (pas de 404)", %{conn: conn} do
      conn = get(conn, ~p"/share/battles/00000000-0000-0000-0000-000000000000")

      # 200 délibéré — un 404 ferait afficher "preview unavailable" côté
      # bot. On préfère un visuel Komun générique.
      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "battle sans photo d'option → og:image = cover Komun par défaut",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building.id, creator.id, %{
          "title" => "Couleur peinture cage",
          "options" => [
            %{"label" => "Blanc cassé"},
            %{"label" => "Crème"}
          ]
        })

      conn = get(conn, ~p"/share/battles/#{battle.id}")

      assert response = response(conn, 200)
      assert response =~ "Couleur peinture cage"
      # Image = default Komun
      assert response =~ "og-default.png"
    end
  end
end
