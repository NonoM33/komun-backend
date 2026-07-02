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

  import Ecto.Query

  alias KomunBackend.{Articles, Battles, Buildings, Events, Projects, Repo, Residences}
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

    test "battle :cancelled → fallback générique (état mort, on n'affiche pas la battle)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, battle} =
        Battles.create_battle(building.id, creator.id, %{
          "title" => "Annulée",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        })

      Repo.update_all(
        from(b in KomunBackend.Battles.Battle, where: b.id == ^battle.id),
        set: [status: :cancelled]
      )

      conn = get(conn, ~p"/share/battles/#{battle.id}")
      assert response = response(conn, 200)
      refute response =~ "Annulée"
      assert response =~ "Komun"
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

  describe "GET /share/articles/:id" do
    test "article publié → og:title + excerpt + cover", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      author = insert_user!(:membre_cs)
      {:ok, _} = Buildings.add_member(building.id, author.id, :membre_cs)

      {:ok, article} =
        Articles.create_article(building.id, author.id, %{
          title: "Travaux du hall — Avant-projet",
          excerpt: "Tour d'horizon des 3 propositions reçues du chantier.",
          content: "Long content markdown ici.",
          cover_url: "https://komun.app/uploads/articles/cover-hall.jpg"
        })

      {:ok, _published} = Articles.transition(article, :published)

      conn = get(conn, ~p"/share/articles/#{article.id}")

      assert response = response(conn, 200)
      assert response =~ "Travaux du hall"
      assert response =~ "Tour d&#39;horizon des 3 propositions"
      assert response =~ "cover-hall.jpg"
    end

    test "article :draft → fallback générique (pas encore publié)",
         %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      author = insert_user!(:membre_cs)
      {:ok, _} = Buildings.add_member(building.id, author.id, :membre_cs)

      {:ok, article} =
        Articles.create_article(building.id, author.id, %{
          title: "Brouillon secret",
          excerpt: "Confidentiel"
        })

      conn = get(conn, ~p"/share/articles/#{article.id}")
      assert response = response(conn, 200)
      refute response =~ "Brouillon secret"
      refute response =~ "Confidentiel"
      assert response =~ "Komun"
    end
  end

  describe "GET /share/projects/:id" do
    test "projet existant → og:title + statut", %{conn: conn} do
      residence = insert_residence!()
      building = insert_building!(residence)
      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, project} =
        Projects.create_project(building.id, creator.id, %{
          title: "Réfection toiture",
          description: "3 devis en cours d'analyse pour la réfection complète."
        })

      conn = get(conn, ~p"/share/projects/#{project.id}")

      assert response = response(conn, 200)
      assert response =~ "Réfection toiture"
      assert response =~ "Collecte de devis"
    end
  end

  describe "GET /share/events/:id — heure locale" do
    test "un event à 8h Paris (06:00 UTC en été) s'affiche « à 08:00 », pas « à 06:00 »",
         %{conn: conn} do
      # Régression : l'aperçu WhatsApp affichait l'heure UTC brute. Un
      # nettoyage des parkings « jeudi 11 juin de 8h à 14h » était stocké
      # 06:00:00Z (Europe/Paris = UTC+2 en juin) et s'affichait « à 06:00 ».
      residence = insert_residence!()
      building = insert_building!(residence)
      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, event} =
        Events.create_event(residence.id, creator, %{
          "title" => "Nettoyage des parkings",
          "description" => "Un nettoyage complet des parkings A et B.",
          "status" => "published",
          "starts_at" => ~U[2026-06-11 06:00:00Z],
          "ends_at" => ~U[2026-06-11 12:00:00Z],
          "location_label" => "Parkings de la résidence"
        })

      conn = get(conn, ~p"/share/events/#{event.id}")

      assert response = response(conn, 200)
      assert response =~ "11/06/2026 à 08:00"
      refute response =~ "à 06:00"
    end

    test "un event en hiver respecte UTC+1 (13:00 UTC → « à 14:00 »)",
         %{conn: conn} do
      # Sécurise le DST : pas d'offset codé en dur. En janvier Paris = UTC+1.
      residence = insert_residence!()
      building = insert_building!(residence)
      creator = insert_user!(:syndic_manager)
      {:ok, _} = Buildings.add_member(building.id, creator.id, :president_cs)

      {:ok, event} =
        Events.create_event(residence.id, creator, %{
          "title" => "Vœux du conseil syndical",
          "status" => "published",
          "starts_at" => ~U[2026-01-15 13:00:00Z],
          "ends_at" => ~U[2026-01-15 15:00:00Z]
        })

      conn = get(conn, ~p"/share/events/#{event.id}")

      assert response = response(conn, 200)
      assert response =~ "15/01/2026 à 14:00"
    end
  end

  describe "rescue ciblé sur les safe_get_* (non-régression)" do
    # Ces tests garantissent que les helpers `safe_get_*` avalent
    # UNIQUEMENT les cas légitimes « ressource introuvable » /
    # « id d'URL malformé » (non-UUID → Ecto.Query.CastError), et pas
    # n'importe quelle exception. Avant, un `rescue _ -> nil` masquait
    # silencieusement une vraie panne BDD (timeout, connexion perdue).
    # On vérifie ici le versant « not found reste bien un not found ».

    test "article : UUID valide inexistant → preview générique (Ecto.NoResultsError capté)",
         %{conn: conn} do
      conn = get(conn, ~p"/share/articles/00000000-0000-0000-0000-000000000000")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "article : id d'URL malformé (non-UUID) → preview générique (Ecto.Query.CastError capté)",
         %{conn: conn} do
      conn = get(conn, ~p"/share/articles/pas-un-uuid")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "battle : id d'URL malformé (non-UUID) → preview générique",
         %{conn: conn} do
      conn = get(conn, ~p"/share/battles/pas-un-uuid")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "projet : UUID valide inexistant → preview générique (Repo.one renvoie nil)",
         %{conn: conn} do
      conn = get(conn, ~p"/share/projects/00000000-0000-0000-0000-000000000000")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "projet : id d'URL malformé (non-UUID) → preview générique (Ecto.Query.CastError capté)",
         %{conn: conn} do
      conn = get(conn, ~p"/share/projects/pas-un-uuid")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "doléance : UUID valide inexistant → preview générique (Repo.get renvoie nil)",
         %{conn: conn} do
      conn = get(conn, ~p"/share/doleances/00000000-0000-0000-0000-000000000000")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end

    test "doléance : id d'URL malformé (non-UUID) → preview générique (Ecto.Query.CastError capté)",
         %{conn: conn} do
      conn = get(conn, ~p"/share/doleances/pas-un-uuid")

      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "og:title"
    end
  end

  describe "GET /share/diligences/:id" do
    test "diligence (CS-only) → toujours preview générique, JAMAIS le titre",
         %{conn: conn} do
      # Diligences sont CS-only par construction. On NE doit JAMAIS
      # afficher leur titre dans iMessage — risque de divulgation
      # (« trouble voisinage 3e étage M. Dupont »).
      conn = get(conn, ~p"/share/diligences/abc-123-not-real-id")
      assert response = response(conn, 200)
      assert response =~ "Komun"
      assert response =~ "copropri"
    end
  end
end
