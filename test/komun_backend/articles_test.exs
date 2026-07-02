defmodule KomunBackend.ArticlesTest do
  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Accounts, Articles, Buildings}
  alias KomunBackend.Articles.Article

  defp insert_building!(attrs \\ %{}) do
    defaults = %{
      "name" => "Bâtiment #{System.unique_integer([:positive])}",
      "address" => "4 rue des Lilas",
      "city" => "Paris",
      "postal_code" => "75015"
    }

    {:ok, building} = Buildings.create_building(Map.merge(defaults, attrs))
    building
  end

  defp insert_user! do
    {:ok, user} =
      Accounts.get_or_create_user("art-#{System.unique_integer([:positive])}@komun.app")

    user
  end

  describe "create_article/3" do
    test "crée un article en brouillon par défaut" do
      building = insert_building!()
      author = insert_user!()

      assert {:ok, %Article{} = article} =
               Articles.create_article(building.id, author.id, %{title: "Le mot du syndic"})

      assert article.title == "Le mot du syndic"
      assert article.status == :draft
      assert article.category == :actualite
      assert article.building_id == building.id
      assert article.author_id == author.id
      assert article.published_at == nil
    end

    test "rejette un article sans titre" do
      building = insert_building!()
      author = insert_user!()

      assert {:error, cs} = Articles.create_article(building.id, author.id, %{title: ""})
      assert %{title: _} = errors_on(cs)
    end

    test "rejette un titre trop long" do
      building = insert_building!()
      author = insert_user!()
      long = String.duplicate("x", 201)

      assert {:error, cs} = Articles.create_article(building.id, author.id, %{title: long})
      assert %{title: _} = errors_on(cs)
    end

    test "ne change pas le statut via create (toujours draft)" do
      building = insert_building!()
      author = insert_user!()

      {:ok, article} =
        Articles.create_article(building.id, author.id, %{title: "X", status: :published})

      assert article.status == :draft
    end
  end

  describe "update_article/2" do
    test "met à jour le contenu sans toucher au statut" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      assert {:ok, updated} =
               Articles.update_article(article, %{
                 content: "Corps de l'article",
                 status: :published
               })

      assert updated.content == "Corps de l'article"
      assert updated.status == :draft
    end

    test "rejette une mise à jour invalide" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      assert {:error, cs} = Articles.update_article(article, %{title: ""})
      assert %{title: _} = errors_on(cs)
    end
  end

  describe "transition/3" do
    test "passe en published et pose published_at automatiquement" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      assert {:ok, published} = Articles.transition(article, :published)
      assert published.status == :published
      assert published.published_at != nil
    end

    test "ne réinitialise pas published_at aux transitions ultérieures" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      {:ok, published} = Articles.transition(article, :published)
      first_published_at = published.published_at

      {:ok, archived} = Articles.transition(published, :archived)
      {:ok, republished} = Articles.transition(archived, :published)

      assert republished.published_at == first_published_at
    end

    test "enregistre la note du relecteur" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      assert {:ok, reviewed} = Articles.transition(article, :review, "À reformuler")
      assert reviewed.status == :review
      assert reviewed.reviewer_note == "À reformuler"
    end
  end

  describe "list_articles/2" do
    setup do
      building = insert_building!()
      author = insert_user!()

      {:ok, draft} = Articles.create_article(building.id, author.id, %{title: "Brouillon"})
      {:ok, pub} = Articles.create_article(building.id, author.id, %{title: "Publié"})
      {:ok, pub} = Articles.transition(pub, :published)

      %{building: building, draft: draft, pub: pub}
    end

    test "par défaut ne remonte que les articles publiés", %{building: building, pub: pub} do
      ids = Articles.list_articles(building.id) |> Enum.map(& &1.id)
      assert ids == [pub.id]
    end

    test ":all remonte tous les statuts", %{building: building, draft: draft, pub: pub} do
      ids = Articles.list_articles(building.id, status: :all) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([draft.id, pub.id])
    end

    test "filtre sur un statut précis", %{building: building, draft: draft} do
      ids = Articles.list_articles(building.id, status: :draft) |> Enum.map(& &1.id)
      assert ids == [draft.id]
    end

    test "épingle les articles en tête", %{building: building} do
      author = insert_user!()

      {:ok, pinned} =
        Articles.create_article(building.id, author.id, %{title: "Épinglé", is_pinned: true})

      {:ok, pinned} = Articles.transition(pinned, :published)

      first = Articles.list_articles(building.id) |> hd()
      assert first.id == pinned.id
    end

    test "isole les articles par bâtiment" do
      b1 = insert_building!()
      b2 = insert_building!()
      author = insert_user!()

      {:ok, a1} = Articles.create_article(b1.id, author.id, %{title: "Chez B1"})
      {:ok, a1} = Articles.transition(a1, :published)
      {:ok, a2} = Articles.create_article(b2.id, author.id, %{title: "Chez B2"})
      {:ok, _} = Articles.transition(a2, :published)

      ids = Articles.list_articles(b1.id) |> Enum.map(& &1.id)
      assert ids == [a1.id]
    end
  end

  describe "get_article!/1 et delete_article/1" do
    test "get_article!/1 précharge l'auteur" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      fetched = Articles.get_article!(article.id)
      assert fetched.id == article.id
      assert fetched.author.id == author.id
    end

    test "get_article!/1 lève pour un id inconnu" do
      assert_raise Ecto.NoResultsError, fn ->
        Articles.get_article!(Ecto.UUID.generate())
      end
    end

    test "delete_article/1 supprime l'article" do
      building = insert_building!()
      author = insert_user!()
      {:ok, article} = Articles.create_article(building.id, author.id, %{title: "X"})

      assert {:ok, _} = Articles.delete_article(article)

      assert_raise Ecto.NoResultsError, fn ->
        Articles.get_article!(article.id)
      end
    end
  end

  describe "editor_roles/0" do
    test "liste les rôles éditeurs" do
      roles = Articles.editor_roles()
      assert :super_admin in roles
      assert :membre_cs in roles
      refute :coproprietaire in roles
    end
  end
end
