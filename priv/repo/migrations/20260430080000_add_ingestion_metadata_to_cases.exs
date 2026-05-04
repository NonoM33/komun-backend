defmodule KomunBackend.Repo.Migrations.AddIngestionMetadataToCases do
  @moduledoc """
  Permet de tracer l'agent AI qui a ingéré chaque dossier (incident /
  doléance / diligence) issu de la routine email : modèle utilisé,
  tokens consommés, coût estimé en USD, latence. Utile pour :

    * comparer les modèles (Opus, Sonnet, Haiku, DeepSeek V4 Flash, …)
    * facturer / surveiller le coût AI à l'échelle d'une résidence
    * identifier les dossiers à re-jouer si on change la stratégie

  Une seule colonne `ai_ingestion_metadata` JSONB pour garder le schéma
  flexible — on n'ajoute pas une nouvelle migration à chaque champ
  qu'un nouveau provider expose. Forme attendue :

      {
        "model": "claude-opus-4-7",
        "provider": "anthropic",
        "input_tokens": 6500,
        "output_tokens": 3000,
        "cost_usd": 0.15,
        "response_ms": 4200,
        "decided_at": "2026-04-30T08:00:00Z"
      }

  Tous les champs sont optionnels — un dossier créé manuellement par un
  copro (formulaire web) aura `ai_ingestion_metadata = nil`.
  """

  use Ecto.Migration

  @tables [:incidents, :doleances, :diligences]

  def change do
    for t <- @tables do
      alter table(t) do
        add :ai_ingestion_metadata, :map, null: true
      end
    end
  end
end
