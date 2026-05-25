defmodule KomunBackend.Repo.Migrations.AddVoteModeAndAllowNoneToBattles do
  @moduledoc """
  Réponses produit au feedback voisin du 2026-05-25 sur la battle
  « Choix des brises vues » :

    Q1 — « il manque une option "ne se prononce pas" / "pas de
          brise-vue" » → on ajoute un flag `allow_none` qui, quand
          activé à la création, fait apparaître une option built-in
          « Aucune des propositions » dans le round 1 (et la qualifie
          pour les rounds suivants si elle reçoit assez de votes).

    Q2 — « pourquoi pas un vote à choix multiples ? » → on ajoute
          `vote_mode` (:single_choice par défaut pour ne pas casser
          l'existant, :multiple_choice opt-in à la création) qui
          autorise un voisin à cocher plusieurs options.

  Pour le multi-choix on relaxe aussi la contrainte unique sur
  `vote_responses` : avant, `(vote_id, user_id)` était unique →
  impossible d'avoir 2 votes pour le même user sur le même vote. On
  passe à deux index partiels :

    * Si `option_id IS NOT NULL` : unique sur `(vote_id, user_id, option_id)`
      — un user peut voter plusieurs options, mais pas deux fois la
        même.
    * Si `option_id IS NULL` (votes binaires yes/no/abstain) : unique
      sur `(vote_id, user_id)` — comportement préservé.

  Cas pré-existants : tous les vote_responses actuels ont soit
  `option_id` set (single_choice) soit `choice` set (binary). Les
  nouveaux index couvrent les deux cas sans rejouer de données.
  """

  use Ecto.Migration

  def up do
    # Champs battle
    alter table(:battles) do
      add :vote_mode, :string, default: "single_choice", null: false
      add :allow_none, :boolean, default: false, null: false
    end

    # Retire la contrainte unique stricte (vote_id, user_id) — elle
    # bloquait le multi-choix. On la remplace par deux index partiels
    # qui couvrent à la fois le binaire (option_id IS NULL) et le
    # single/multi-choix (option_id IS NOT NULL).
    drop_if_exists unique_index(:vote_responses, [:vote_id, :user_id])

    create unique_index(
             :vote_responses,
             [:vote_id, :user_id, :option_id],
             name: :vote_responses_user_option_uniq,
             where: "option_id IS NOT NULL"
           )

    create unique_index(
             :vote_responses,
             [:vote_id, :user_id],
             name: :vote_responses_user_binary_uniq,
             where: "option_id IS NULL"
           )
  end

  def down do
    drop_if_exists index(:vote_responses, [:vote_id, :user_id, :option_id],
                     name: :vote_responses_user_option_uniq
                   )

    drop_if_exists index(:vote_responses, [:vote_id, :user_id],
                     name: :vote_responses_user_binary_uniq
                   )

    create unique_index(:vote_responses, [:vote_id, :user_id])

    alter table(:battles) do
      remove :allow_none
      remove :vote_mode
    end
  end
end
