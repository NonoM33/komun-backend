defmodule KomunBackend.AI.Ingestion.Provider do
  @moduledoc """
  Behaviour commun aux providers d'ingestion AI (Anthropic, DeepSeek,
  OpenAI, …). Permet à `Runner` de dispatcher vers le bon client en
  fonction du modèle choisi sans connaître les détails de chaque API.

  Chaque provider implémente `complete/3` qui prend :

    * `model_id` (str) — l'id du modèle (cf. `Models.list/0`)
    * `messages` (liste) — `[%{role: "system" | "user" | "assistant", content: "..."}]`
    * `opts` (kw) — options libres :
      - `:max_tokens` (int)
      - `:temperature` (float)
      - `:timeout_ms` (int, défaut 60_000)

  Et renvoie soit :

    * `{:ok, %{content: str, input_tokens: int, output_tokens: int,
       finish_reason: str | nil, raw: map}}`
    * `{:error, reason}` (atom ou message lisible)

  Le calcul du coût est délégué à `Runner` qui appelle `Models.estimate_cost/3`
  — un provider ne doit pas tricher en renvoyant un `cost_usd` hors-bande.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: keyword()

  @type ok_result :: %{
          required(:content) => String.t(),
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          optional(:finish_reason) => String.t() | nil,
          optional(:raw) => map()
        }

  @callback complete(model_id :: String.t(), messages :: [message()], opts :: opts()) ::
              {:ok, ok_result()} | {:error, term()}
end
