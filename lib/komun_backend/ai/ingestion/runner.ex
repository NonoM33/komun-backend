defmodule KomunBackend.AI.Ingestion.Runner do
  @moduledoc """
  Point d'entrée unifié pour appeler n'importe quel modèle d'ingestion AI.

  Fait l'aiguillage `model_id` → provider implémentant
  `KomunBackend.AI.Ingestion.Provider`, et enrichit la réponse avec un
  coût USD calculé à partir des tokens et du registre `Models`.

  ## Exemple

  ```elixir
  iex> messages = [
  ...>   %{role: "system", content: "Tu es un agent qui catégorise des emails…"},
  ...>   %{role: "user", content: "Bonjour, l'ascenseur est en panne…"}
  ...> ]
  iex> KomunBackend.AI.Ingestion.Runner.run("deepseek-v4-flash", messages)
  {:ok,
   %{
     model: "deepseek-v4-flash",
     provider: :deepseek,
     content: "INCIDENT — ascenseur — high…",
     input_tokens: 800,
     output_tokens: 250,
     cost_usd: 0.0002,
     response_ms: 850,
     finish_reason: "stop"
   }}
  ```

  Le `:response_ms` est mesuré côté client (depuis l'appel à `run/3`
  jusqu'au retour du provider), donc inclut la latence réseau aller-
  retour. C'est le "temps perçu" — c'est ce qu'on veut pour la
  comparaison.
  """

  require Logger

  alias KomunBackend.AI.Ingestion.{Models, Provider}
  alias KomunBackend.AI.Ingestion.Providers

  @type opts :: keyword()

  @type ok_result :: %{
          required(:model) => String.t(),
          required(:provider) => atom(),
          required(:content) => String.t(),
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:cost_usd) => float(),
          required(:response_ms) => non_neg_integer(),
          optional(:finish_reason) => String.t() | nil
        }

  @doc """
  Lance le modèle `model_id` sur la conversation `messages`, renvoie
  le résultat enrichi avec coût + latence.
  """
  @spec run(String.t(), [Provider.message()], opts()) ::
          {:ok, ok_result()} | {:error, term()}
  def run(model_id, messages, opts \\ []) do
    case Models.get(model_id) do
      nil ->
        {:error, {:unknown_model, model_id}}

      model ->
        do_run(model, messages, opts)
    end
  end

  defp do_run(%{id: id, provider: provider} = _model, messages, opts) do
    started_at = System.monotonic_time(:millisecond)

    case provider_module(provider).complete(id, messages, opts) do
      {:ok, %{input_tokens: it, output_tokens: ot} = res} ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        {:ok,
         %{
           model: id,
           provider: provider,
           content: res.content,
           input_tokens: it,
           output_tokens: ot,
           cost_usd: Models.estimate_cost(id, it, ot),
           response_ms: elapsed,
           finish_reason: Map.get(res, :finish_reason)
         }}

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - started_at
        Logger.warning("[ai-ingestion] #{id} failed in #{elapsed}ms: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Lance plusieurs modèles **en parallèle** sur les mêmes messages —
  c'est la primitive de la page de comparaison admin.

  Renvoie une map `%{model_id => {:ok, result} | {:error, reason}}`.
  Aucun crash si un seul modèle échoue : les autres remontent leur
  résultat normalement (pas de logique tout-ou-rien).
  """
  @spec run_many([String.t()], [Provider.message()], opts()) :: %{String.t() => {:ok, ok_result()} | {:error, term()}}
  def run_many(model_ids, messages, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 90_000)

    model_ids
    |> Enum.uniq()
    |> Task.async_stream(
      fn id -> {id, run(id, messages, opts)} end,
      timeout: timeout,
      on_timeout: :kill_task,
      max_concurrency: max(length(model_ids), 1)
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, result}}, acc -> Map.put(acc, id, result)
      {:exit, :timeout}, acc -> acc
      {:exit, reason}, acc -> Map.put(acc, "<unknown>", {:error, {:exit, reason}})
    end)
  end

  defp provider_module(:anthropic), do: Providers.Anthropic
  defp provider_module(:deepseek), do: Providers.DeepSeek

  defp provider_module(other),
    do: raise(ArgumentError, "Provider non supporté : #{inspect(other)}")
end
