defmodule KomunBackend.Diligences.Steps do
  @moduledoc """
  Constantes des 9 étapes d'une diligence (procédure trouble anormal du
  voisinage). Le mapping est partagé entre le backend (où on persiste
  `step_number: 1..9` dans `diligence_steps`) et le frontend, qui
  duplique la même liste. Toute modification ici doit être répliquée
  côté `web_v2/src/features/diligences/steps.ts` — un test
  d'intégration end-to-end vérifie que les deux côtés sont alignés.

  Pourquoi on stocke `step_number` (entier) plutôt qu'un atom Ecto.Enum :
  - permet d'ajouter une étape sans migration (juste une nouvelle entrée
    dans cette liste + seed des diligences existantes)
  - rend l'ordre explicite et trivial à trier en SQL
  - évite la sérialisation atom vs string côté JSON
  """

  @steps [
    %{n: 1, key: :cadrage, title: "Cadrer le rôle de chacun"},
    %{n: 2, key: :collecte_preuves, title: "Collecter les preuves"},
    %{n: 3, key: :identifier_source, title: "Identifier la source (copro vs locataire)"},
    %{n: 4, key: :amiable, title: "Première démarche amiable"},
    %{n: 5, key: :saisine_syndic, title: "Saisine officielle du syndic (LRAR)"},
    %{n: 6, key: :mise_en_demeure, title: "Mise en demeure par le syndic"},
    %{n: 7, key: :plainte_police, title: "Plainte police / gendarmerie (optionnel)"},
    %{n: 8, key: :conciliateur, title: "Conciliateur de justice"},
    %{n: 9, key: :judiciaire, title: "Action judiciaire (dernier recours)"}
  ]

  @numbers Enum.map(@steps, & &1.n)

  def all, do: @steps
  def numbers, do: @numbers
  def count, do: length(@steps)

  def title(n) when is_integer(n) do
    case Enum.find(@steps, &(&1.n == n)) do
      nil -> nil
      step -> step.title
    end
  end

  def valid_number?(n) when is_integer(n), do: n in @numbers
  def valid_number?(_), do: false
end
