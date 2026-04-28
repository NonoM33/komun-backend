defmodule KomunBackend.DocumentsContextForAiTest do
  @moduledoc """
  Régression du bug "l'assistant ne lit pas le règlement" (avril 2026).

  Avant la correction :
  - `Documents.context_for_ai/3` concaténait simplement les contenus
    bruts dans l'ordre de priorité (épinglé > catégorie > fraîcheur),
    avec une troncature dure à 60 000 caractères. Sur un règlement
    volumineux, la section qui répondait à la question pouvait
    silencieusement tomber dans la queue tronquée → l'IA répondait
    « Le règlement ne traite pas explicitement ce point ».
  - Aucun signal de la question n'était transmis au retrieval.

  Cette suite gèle la nouvelle sémantique :
  - `context_for_ai/3` accepte `question:` dans `opts`,
  - les paragraphes contenant les tokens de la question sont remontés
    en priorité au sein de chaque document, même quand la section
    pertinente se trouve loin dans le texte,
  - sans question, le comportement legacy (concat ordonné) est préservé,
  - l'API arity-3 historique avec un entier `max_chars` reste valide.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Documents, Repo, Residences}
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Documents.Document
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

  defp insert_building! do
    residence = insert_residence!()

    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "1 rue de la Paix",
      city: "Paris",
      postal_code: "75002",
      residence_id: residence.id,
      join_code: KomunBackend.Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_reglement!(building_id, content_text, opts \\ []) do
    %Document{}
    |> Document.changeset(%{
      title: Keyword.get(opts, :title, "Règlement de copropriété"),
      category: :reglement,
      is_public: true,
      content_text: content_text,
      building_id: building_id
    })
    |> Repo.insert!()
  end

  describe "context_for_ai/3 with :question option" do
    test "surfaces the keyword-matching paragraph even when it sits past the budget cap" do
      building = insert_building!()

      filler =
        1..120
        |> Enum.map(fn i ->
          "Article #{i} — Disposition générique sans rapport. " <>
            "Ce paragraphe parle de chauffage, ascenseur, ravalement, syndic et copropriétaires. " <>
            String.duplicate("Texte de remplissage. ", 30)
        end)
        |> Enum.join("\n\n")

      target =
        "Article 121 — Tabac dans les jardins privatifs. " <>
          "Il est strictement interdit de jeter les mégots dans les massifs. " <>
          "L'usage du tabac doit respecter la tranquillité des autres occupants."

      content = filler <> "\n\n" <> target

      insert_reglement!(building.id, content)

      ctx =
        Documents.context_for_ai(building.id, :coproprietaire,
          question: "On peut fumer dans les jardins ?",
          max_chars: 8_000
        )

      # Naïve concat with cap < 8 000 chars would truncate the file long
      # before article 121. The ranked context must surface it anyway.
      assert ctx =~ "Article 121"
      assert ctx =~ "Tabac dans les jardins"
      assert String.length(ctx) <= 8_000
    end

    test "still includes the document head as fallback even when no paragraph matches the question" do
      building = insert_building!()

      content =
        "Article 1 — Préambule. " <>
          "Ce règlement s'applique à l'ensemble des copropriétaires.\n\n" <>
          String.duplicate(
            "Article filler. Disposition variée sur la copropriété, charges, AG, syndic. ",
            200
          )

      insert_reglement!(building.id, content)

      ctx =
        Documents.context_for_ai(building.id, :coproprietaire,
          question: "Je veux installer une éolienne lunaire",
          max_chars: 4_000
        )

      assert ctx =~ "Préambule"
      assert String.length(ctx) <= 4_000
    end

    test "ignores the question when it contains only stop-words / short tokens" do
      building = insert_building!()
      content = "Article 1 — Très court règlement.\n\nArticle 2 — Encore plus court."
      insert_reglement!(building.id, content)

      ctx =
        Documents.context_for_ai(building.id, :coproprietaire,
          question: "et le ?",
          max_chars: 60_000
        )

      assert ctx =~ "Article 1"
      assert ctx =~ "Article 2"
    end
  end

  describe "context_for_ai/3 without :question (legacy concat)" do
    test "preserves backward-compat with arity-3 integer max_chars" do
      building = insert_building!()
      insert_reglement!(building.id, "Article 1 — Court règlement.")

      ctx = Documents.context_for_ai(building.id, :coproprietaire, 60_000)

      assert ctx =~ "Article 1"
      assert ctx =~ "Règlement de copropriété"
    end

    test "concatenates documents in priority order when no question is given" do
      building = insert_building!()
      insert_reglement!(building.id, "Article unique du règlement.")

      ctx = Documents.context_for_ai(building.id, :coproprietaire)

      assert ctx =~ "Article unique"
    end
  end

  describe "role scoping" do
    test "résidents only see :reglement category, not other public documents" do
      building = insert_building!()
      insert_reglement!(building.id, "Contenu du règlement de copropriété.")

      %Document{}
      |> Document.changeset(%{
        title: "PV AG 2025",
        category: :pv_ag,
        is_public: true,
        content_text: "Procès-verbal d'assemblée générale, points votés.",
        building_id: building.id
      })
      |> Repo.insert!()

      ctx_resident =
        Documents.context_for_ai(building.id, :coproprietaire,
          question: "procès-verbal assemblée"
        )

      assert ctx_resident =~ "règlement"
      refute ctx_resident =~ "Procès-verbal d'assemblée"

      ctx_syndic =
        Documents.context_for_ai(building.id, :syndic_manager,
          question: "procès-verbal assemblée"
        )

      assert ctx_syndic =~ "Procès-verbal d'assemblée"
    end
  end
end
