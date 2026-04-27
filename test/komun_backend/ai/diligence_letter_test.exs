defmodule KomunBackend.AI.DiligenceLetterTest do
  @moduledoc """
  Tests du module de génération de courriers. On vérifie surtout le
  fallback statique : sans clé Groq, l'utilisateur doit recevoir un
  template figé exploitable plutôt qu'une erreur.

  Note : on ne teste pas la branche "appel Groq réussi" parce qu'elle
  exigerait soit un mock HTTP (overkill pour la valeur ajoutée), soit
  une vraie clé en CI (interdit). Les prompts système sont relus
  manuellement à la PR.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Diligences, Residences}
  alias KomunBackend.AI.DiligenceLetter
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Residences.Residence

  setup do
    # Garantit que GROQ_API_KEY est absente pour qu'on tape le fallback.
    previous = System.get_env("GROQ_API_KEY")
    System.delete_env("GROQ_API_KEY")
    on_exit(fn -> if previous, do: System.put_env("GROQ_API_KEY", previous) end)
    :ok
  end

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

  defp setup_diligence(attrs \\ %{}) do
    residence = insert_residence!()
    building = insert_building!(residence)

    user =
      %User{}
      |> User.changeset(%{
        email: "user#{System.unique_integer([:positive])}@test.local",
        role: :coproprietaire
      })
      |> Repo.insert!()

    {:ok, _} = Buildings.add_member(building.id, user.id, :president_cs)

    base = %{"title" => "Odeurs cannabis lot 14"}

    {:ok, d} = Diligences.create_diligence(building.id, user, Map.merge(base, attrs))
    d
  end

  describe "generate_letter/2 (sans clé Groq → fallback statique)" do
    test "saisine : retourne un template qui mentionne le titre, le syndic et CERFA" do
      d =
        setup_diligence(%{
          "description" => "Odeurs persistantes via la VMC",
          "source_type" => "copro_owner",
          "source_label" => "M. Untel, lot 14"
        })

      assert {:ok, updated} = DiligenceLetter.generate_letter(d, :saisine)

      letter = updated.saisine_syndic_letter
      assert is_binary(letter)

      assert letter =~ "Saisine officielle"
      assert letter =~ "Odeurs cannabis lot 14"
      assert letter =~ "Odeurs persistantes via la VMC"
      assert letter =~ "CERFA"
      assert letter =~ "L3421-1"
      assert letter =~ "M. Untel, lot 14"
      assert letter =~ "Le Président du conseil syndical"
    end

    test "mise_en_demeure : retourne un template adressé au copropriétaire" do
      d = setup_diligence(%{"source_type" => "tenant", "source_label" => "Locataire 1B"})

      assert {:ok, updated} = DiligenceLetter.generate_letter(d, :mise_en_demeure)

      letter = updated.mise_en_demeure_letter
      assert is_binary(letter)

      assert letter =~ "Mise en demeure"
      # Le template peut avoir un saut de ligne entre tokens (wrap 70 cols)
      # — on matche des fragments suffisamment courts pour ne pas tomber dessus.
      assert letter =~ "recommandée"
      assert letter =~ "1240"
      assert letter =~ "1729 du Code civil"
      assert letter =~ "Le Syndic"
    end

    test "rejette un kind inconnu" do
      d = setup_diligence()

      assert {:error, {:invalid_kind, :coucou, _}} =
               DiligenceLetter.generate_letter(d, :coucou)
    end

    test "preview/2 retourne {:ok, text, :static} en mode fallback" do
      d = setup_diligence()

      assert {:ok, text, :static} = DiligenceLetter.preview(d, :saisine)
      assert is_binary(text)
      assert text =~ "Saisine officielle"
    end
  end

  describe "static_template/2" do
    test "saisine inclut la source_type tenant quand pertinent" do
      d = setup_diligence(%{"source_type" => "tenant"})
      letter = DiligenceLetter.static_template(d, :saisine)
      assert letter =~ "Locataire"
    end

    test "saisine reste générique si source_type est nil" do
      d = setup_diligence()
      letter = DiligenceLetter.static_template(d, :saisine)
      assert letter =~ "non précisée"
    end
  end
end
