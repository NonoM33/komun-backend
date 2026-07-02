defmodule KomunBackend.DoleancesTest do
  @moduledoc """
  Tests unitaires du contexte Doleances (doléances collectives escaladées
  vers le syndic / constructeur / tiers).

  Couvre les fonctions publiques réellement exposées :

  - CRUD nominal (`create_doleance/3`, `get_doleance/1`, `get_doleance!/1`,
    `update_doleance/3`, `delete_doleance/1`)
  - Le workflow de statut : brouillon → open → escalated → resolved →
    closed / rejected via `escalate/2`, `resolve/3`, `close/2`, `reject/2`
  - La timeline d'événements (`list_events/1`) alimentée à chaque transition
  - Les co-signatures (`upsert_support/3`, `remove_support/2`)
  - La visibilité des brouillons dans `list_doleances/3`
  - Cas d'erreur (changeset invalide)
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Doleances, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Doleances.{Doleance, DoleanceFile, DoleanceSupport}
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

  defp setup_building_and_author do
    residence = insert_residence!()
    building = insert_building!(residence)
    author = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, author.id, :coproprietaire)
    {building, author}
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Infiltrations récurrentes garage sous-sol",
        "description" => "Plusieurs copropriétaires constatent des infiltrations.",
        "category" => "structure"
      },
      overrides
    )
  end

  defp create!(building, author, overrides \\ %{}) do
    {:ok, d} = Doleances.create_doleance(building.id, author.id, valid_attrs(overrides))
    d
  end

  describe "create_doleance/3" do
    test "crée une doléance avec les valeurs par défaut" do
      {building, author} = setup_building_and_author()

      assert {:ok, %Doleance{} = d} =
               Doleances.create_doleance(building.id, author.id, valid_attrs())

      assert d.title == "Infiltrations récurrentes garage sous-sol"
      assert d.category == :structure
      assert d.status == :open
      assert d.severity == :medium
      assert d.building_id == building.id
      assert d.author_id == author.id
    end

    test "force building_id et author_id même s'ils sont dans attrs (verrou)" do
      {building, author} = setup_building_and_author()
      other = insert_user!()

      {:ok, d} =
        Doleances.create_doleance(
          building.id,
          author.id,
          valid_attrs(%{
            "building_id" => Ecto.UUID.generate(),
            "author_id" => other.id
          })
        )

      assert d.building_id == building.id
      assert d.author_id == author.id
    end

    test "enregistre un événement :created à la création" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      events = Doleances.list_events(d.id)
      assert Enum.any?(events, &(&1.event_type == :created))
    end

    test "rejette un titre trop court" do
      {building, author} = setup_building_and_author()

      assert {:error, %Ecto.Changeset{} = cs} =
               Doleances.create_doleance(building.id, author.id, valid_attrs(%{"title" => "abc"}))

      assert "should be at least 5 character(s)" in errors_on(cs).title
    end

    test "rejette une description trop courte" do
      {building, author} = setup_building_and_author()

      assert {:error, %Ecto.Changeset{} = cs} =
               Doleances.create_doleance(
                 building.id,
                 author.id,
                 valid_attrs(%{"description" => "court"})
               )

      assert "should be at least 10 character(s)" in errors_on(cs).description
    end
  end

  describe "get_doleance/1 & get_doleance!/1" do
    test "get_doleance/1 retourne la doléance ou nil" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert %Doleance{id: id} = Doleances.get_doleance(d.id)
      assert id == d.id
      assert is_nil(Doleances.get_doleance(Ecto.UUID.generate()))
    end

    test "get_doleance!/1 précharge les associations" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      loaded = Doleances.get_doleance!(d.id)
      assert loaded.author.id == author.id
      assert is_list(loaded.files)
      assert is_list(loaded.supports)
    end
  end

  describe "update_doleance/3" do
    test "met à jour un champ éditable" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert {:ok, updated} =
               Doleances.update_doleance(d, %{"target_name" => "Cabinet Syndic ABC"})

      assert updated.target_name == "Cabinet Syndic ABC"
    end

    test "enregistre un événement :status_change quand le statut bouge" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      {:ok, _} = Doleances.update_doleance(d, %{"status" => "closed"}, author.id)

      events = Doleances.list_events(d.id)
      status_change = Enum.find(events, &(&1.event_type == :status_change))
      assert status_change
      assert status_change.payload["to"] == "closed"
    end

    test "n'enregistre pas de status_change si le statut ne bouge pas" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      {:ok, _} = Doleances.update_doleance(d, %{"target_name" => "X"}, author.id)

      refute Enum.any?(Doleances.list_events(d.id), &(&1.event_type == :status_change))
    end
  end

  describe "workflow: escalate / resolve / close / reject" do
    test "escalate/2 passe à escalated et horodate + journalise" do
      {building, author} = setup_building_and_author()
      d = create!(building, author, %{"target_name" => "Syndic X", "target_kind" => "syndic"})

      assert {:ok, escalated} = Doleances.escalate(d, author.id)
      assert escalated.status == :escalated
      refute is_nil(escalated.escalated_at)

      assert Enum.any?(Doleances.list_events(d.id), &(&1.event_type == :escalated))
    end

    test "resolve/3 passe à resolved avec note + horodatage + événement" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert {:ok, resolved} = Doleances.resolve(d, "Réparé par le constructeur.", author.id)
      assert resolved.status == :resolved
      assert resolved.resolution_note == "Réparé par le constructeur."
      refute is_nil(resolved.resolved_at)

      assert Enum.any?(Doleances.list_events(d.id), &(&1.event_type == :resolved))
    end

    test "close/2 passe à closed + événement" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert {:ok, closed} = Doleances.close(d, author.id)
      assert closed.status == :closed

      assert Enum.any?(Doleances.list_events(d.id), &(&1.event_type == :closed))
    end

    test "reject/2 passe à rejected + événement" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert {:ok, rejected} = Doleances.reject(d, author.id)
      assert rejected.status == :rejected

      assert Enum.any?(Doleances.list_events(d.id), &(&1.event_type == :rejected))
    end

    test "workflow complet brouillon → open → escalated → resolved" do
      {building, author} = setup_building_and_author()

      draft = create!(building, author, %{"status" => "brouillon"})
      assert draft.status == :brouillon

      {:ok, opened} = Doleances.update_doleance(draft, %{"status" => "open"}, author.id)
      assert opened.status == :open

      {:ok, escalated} = Doleances.escalate(opened, author.id)
      assert escalated.status == :escalated

      {:ok, resolved} = Doleances.resolve(escalated, "OK", author.id)
      assert resolved.status == :resolved

      types = Doleances.list_events(draft.id) |> Enum.map(& &1.event_type)
      assert :created in types
      assert :status_change in types
      assert :escalated in types
      assert :resolved in types
    end
  end

  describe "list_events/1 ordering" do
    test "retourne les événements par ordre chronologique croissant" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)
      {:ok, _} = Doleances.escalate(d, author.id)
      {:ok, _} = Doleances.resolve(d, "note", author.id)

      types = Doleances.list_events(d.id) |> Enum.map(& &1.event_type)
      assert List.first(types) == :created
    end
  end

  describe "co-signatures" do
    test "upsert_support/3 crée puis met à jour sans doublon" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)
      supporter = insert_user!()

      assert {:ok, %DoleanceSupport{} = s1} =
               Doleances.upsert_support(d.id, supporter.id, %{"comment" => "Je confirme."})

      assert s1.comment == "Je confirme."

      assert {:ok, s2} =
               Doleances.upsert_support(d.id, supporter.id, %{"comment" => "Mise à jour."})

      assert s2.id == s1.id
      assert s2.comment == "Mise à jour."

      count =
        Repo.aggregate(
          from(s in DoleanceSupport, where: s.doleance_id == ^d.id),
          :count
        )

      assert count == 1
    end

    test "upsert_support/3 journalise :support_added uniquement à la première signature" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)
      supporter = insert_user!()

      {:ok, _} = Doleances.upsert_support(d.id, supporter.id, %{"comment" => "A"})
      {:ok, _} = Doleances.upsert_support(d.id, supporter.id, %{"comment" => "B"})

      added = Enum.filter(Doleances.list_events(d.id), &(&1.event_type == :support_added))
      assert length(added) == 1
    end

    test "remove_support/2 supprime la co-signature et journalise" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)
      supporter = insert_user!()

      {:ok, _} = Doleances.upsert_support(d.id, supporter.id, %{"comment" => "A"})
      assert :ok = Doleances.remove_support(d.id, supporter.id)

      count =
        Repo.aggregate(
          from(s in DoleanceSupport, where: s.doleance_id == ^d.id),
          :count
        )

      assert count == 0
      assert Enum.any?(Doleances.list_events(d.id), &(&1.event_type == :support_removed))
    end
  end

  describe "list_doleances/3 visibility" do
    test "cache les brouillons aux résidents lambda" do
      {building, author} = setup_building_and_author()

      _draft = create!(building, author, %{"status" => "brouillon"})
      open = create!(building, author)

      ids = Doleances.list_doleances(building.id, %{}, author) |> Enum.map(& &1.id)
      assert open.id in ids
      assert length(ids) == 1
    end

    test "montre les brouillons aux privilégiés (président CS)" do
      {building, author} = setup_building_and_author()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

      draft = create!(building, author, %{"status" => "brouillon"})

      ids = Doleances.list_doleances(building.id, %{}, president) |> Enum.map(& &1.id)
      assert draft.id in ids
    end

    test "filtre par status" do
      {building, author} = setup_building_and_author()
      president = insert_user!()
      {:ok, _} = Buildings.add_member(building.id, president.id, :president_cs)

      open = create!(building, author)
      other = create!(building, author)
      {:ok, _} = Doleances.close(other, author.id)

      open_ids =
        Doleances.list_doleances(building.id, %{"status" => "open"}, president)
        |> Enum.map(& &1.id)

      assert open.id in open_ids
      refute other.id in open_ids
    end

    test "isole les doléances par bâtiment" do
      {building_a, author_a} = setup_building_and_author()
      {building_b, author_b} = setup_building_and_author()

      d_a = create!(building_a, author_a)
      _d_b = create!(building_b, author_b)

      ids = Doleances.list_doleances(building_a.id, %{}, author_a) |> Enum.map(& &1.id)
      assert d_a.id in ids
      assert length(ids) == 1
    end
  end

  describe "delete_doleance/1" do
    test "supprime la doléance" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert {:ok, _} = Doleances.delete_doleance(d)
      assert is_nil(Doleances.get_doleance(d.id))
    end
  end

  describe "files" do
    test "attach_file/3, get_file!/1 puis delete_file/1" do
      {building, author} = setup_building_and_author()
      d = create!(building, author)

      assert {:ok, %DoleanceFile{} = file} =
               Doleances.attach_file(d.id, author, %{
                 "kind" => "document",
                 "filename" => "constat.pdf",
                 "file_url" => "/uploads/constat.pdf",
                 "mime_type" => "application/pdf",
                 "file_size_bytes" => 2048
               })

      assert file.doleance_id == d.id
      assert file.uploaded_by_id == author.id
      assert Doleances.get_file!(file.id).id == file.id

      assert {:ok, _} = Doleances.delete_file(file)
      assert is_nil(Repo.get(DoleanceFile, file.id))
    end
  end
end
