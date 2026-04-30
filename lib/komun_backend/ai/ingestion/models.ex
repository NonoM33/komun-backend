defmodule KomunBackend.AI.Ingestion.Models do
  @moduledoc """
  Registre des modèles supportés pour l'ingestion AI des emails.

  Chaque entrée déclare :

    * `:id` — identifiant stable (utilisé par le setting résidence et
      stocké dans `ai_ingestion_metadata.model`)
    * `:label` — nom lisible affiché dans la UI admin
    * `:provider` — atom `:anthropic` | `:deepseek` | `:openai` (utilisé
      par `Runner` pour dispatcher vers le bon client)
    * `:input_per_million_usd` / `:output_per_million_usd` — pricing par
      million de tokens, utilisé pour calculer `cost_usd` post-call
    * `:context_window` — taille max du contexte en tokens
    * `:notes` — texte court qui s'affiche dans la UI admin pour aider
      à choisir (« plus rapide », « pas cher », « meilleur en français »)

  Pour ajouter un modèle : append dans `@models`. C'est tout — le
  Runner et l'UI lisent ce registre dynamiquement.

  ## Pricing source

  Les prix d'avril 2026 :

    * Anthropic : https://www.anthropic.com/pricing
    * DeepSeek : https://api-docs.deepseek.com/quick_start/pricing

  À mettre à jour quand un provider change ses tarifs (rare).
  """

  @models [
    %{
      id: "claude-opus-4-7",
      label: "Claude Opus 4.7",
      provider: :anthropic,
      input_per_million_usd: 15.0,
      output_per_million_usd: 75.0,
      context_window: 1_000_000,
      notes: "Meilleur raisonnement français + juridique copro. Cher."
    },
    %{
      id: "claude-sonnet-4-6",
      label: "Claude Sonnet 4.6",
      provider: :anthropic,
      input_per_million_usd: 3.0,
      output_per_million_usd: 15.0,
      context_window: 1_000_000,
      notes: "Bon compromis qualité / prix. ~5× moins cher qu'Opus."
    },
    %{
      id: "claude-haiku-4-5",
      label: "Claude Haiku 4.5",
      provider: :anthropic,
      input_per_million_usd: 0.8,
      output_per_million_usd: 4.0,
      context_window: 200_000,
      notes: "Le plus rapide d'Anthropic. Parfait pour le triage léger."
    },
    %{
      id: "deepseek-v4-flash",
      label: "DeepSeek V4 Flash",
      provider: :deepseek,
      input_per_million_usd: 0.14,
      output_per_million_usd: 0.28,
      context_window: 1_000_000,
      notes: "Open source MoE 284B/13B activés. ~100× moins cher qu'Opus."
    },
    %{
      id: "deepseek-v4-pro",
      label: "DeepSeek V4 Pro",
      provider: :deepseek,
      input_per_million_usd: 0.435,
      output_per_million_usd: 0.87,
      context_window: 1_000_000,
      notes: "Variante 1.6T/49B activés — meilleur raisonnement que Flash."
    }
  ]

  @doc "Liste tous les modèles supportés."
  @spec list() :: [map()]
  def list, do: @models

  @doc """
  Renvoie le modèle correspondant à l'`id` ou `nil`.

  Voir aussi `fetch!/1` qui lève si l'id est inconnu.
  """
  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id), do: Enum.find(@models, &(&1.id == id))
  def get(_), do: nil

  @doc "Comme `get/1` mais lève `ArgumentError` si l'id est inconnu."
  @spec fetch!(String.t()) :: map()
  def fetch!(id) do
    case get(id) do
      nil -> raise ArgumentError, "Modèle d'ingestion AI inconnu : #{inspect(id)}"
      model -> model
    end
  end

  @doc """
  Identifiant du modèle utilisé par défaut quand la résidence n'a pas
  surchargé le setting. Voir Phase 3 (setting `residences.ingestion_model_id`).
  """
  @spec default_id() :: String.t()
  def default_id, do: "claude-opus-4-7"

  @doc """
  Calcule le coût en USD à partir des tokens consommés et du modèle.

  ```elixir
  iex> KomunBackend.AI.Ingestion.Models.estimate_cost("deepseek-v4-flash", 6500, 3000)
  # ~0.0017
  ```
  """
  @spec estimate_cost(String.t(), non_neg_integer(), non_neg_integer()) :: float()
  def estimate_cost(model_id, input_tokens, output_tokens) do
    model = fetch!(model_id)

    input_cost = input_tokens / 1_000_000 * model.input_per_million_usd
    output_cost = output_tokens / 1_000_000 * model.output_per_million_usd

    Float.round(input_cost + output_cost, 6)
  end
end
