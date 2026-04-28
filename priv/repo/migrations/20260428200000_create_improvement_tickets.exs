defmodule KomunBackend.Repo.Migrations.CreateImprovementTickets do
  use Ecto.Migration

  @moduledoc """
  Tickets de feedback produit (bugs, idées, demandes d'amélioration)
  remontés par les utilisateurs depuis la page « Améliorations ».

  Ressource **globale** (pas scopée à un bâtiment) — c'est du retour
  produit destiné à l'équipe Komun, pas une réclamation interne à
  une copropriété. Les super_admin voient tout, l'auteur voit ses
  propres tickets. On garde un `building_id` optionnel à titre de
  contexte (savoir d'où vient le retour) sans en faire une clé
  d'autorisation.
  """

  def change do
    create table(:improvement_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :kind, :string, null: false
      add :title, :string, null: false
      add :description, :text, null: false
      add :status, :string, null: false, default: "open"

      # Réponse / note de l'équipe Komun, visible par l'auteur.
      add :admin_note, :text

      add :author_id,
          references(:users, type: :binary_id, on_delete: :nilify_all),
          null: false

      # Contexte uniquement — sert à savoir d'où vient le retour. Pas
      # de cascade sur suppression : si le bâtiment disparaît, le ticket
      # reste lisible côté admin pour archive.
      add :building_id,
          references(:buildings, type: :binary_id, on_delete: :nilify_all)

      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:improvement_tickets, [:author_id])
    create index(:improvement_tickets, [:status])
    create index(:improvement_tickets, [:kind])
    create index(:improvement_tickets, [:inserted_at])
  end
end
