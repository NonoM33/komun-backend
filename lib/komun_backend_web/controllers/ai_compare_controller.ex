defmodule KomunBackendWeb.AiCompareController do
  @moduledoc """
  Endpoints admin pour comparer plusieurs modèles d'ingestion AI sur
  un même prompt.

  ## Routes

    * `GET  /api/v1/admin/ai/models` → liste les modèles supportés
      (id, label, provider, pricing, notes). Lu par la page de
      comparaison côté front pour peupler les checkboxes.

    * `POST /api/v1/admin/ai/compare-ingestion` → lance N modèles en
      parallèle sur les mêmes `messages`. Renvoie pour chacun le
      contenu généré, les tokens consommés, le coût et la latence.

  ## Authorization

  Réservé `super_admin` global. Pour l'instant on ne donne pas l'accès
  au syndic / CS — la page de comparaison est un outil interne (Komun
  équipe) pour décider quel modèle déployer par défaut. Si on veut
  l'ouvrir aux gestionnaires plus tard, ajuster `authorize_admin/1`.

  ## Body de `POST /admin/ai/compare-ingestion`

  ```json
  {
    "model_ids": ["claude-opus-4-7", "deepseek-v4-flash"],
    "messages": [
      {"role": "system", "content": "Tu es un agent qui catégorise…"},
      {"role": "user", "content": "Bonjour, l'ascenseur est en panne…"}
    ],
    "max_tokens": 4096,
    "temperature": 0.0
  }
  ```

  ## Réponse

  ```json
  {
    "results": {
      "claude-opus-4-7": {
        "ok": true,
        "content": "…",
        "input_tokens": 800,
        "output_tokens": 250,
        "cost_usd": 0.030750,
        "response_ms": 4200,
        "finish_reason": "end_turn"
      },
      "deepseek-v4-flash": {
        "ok": true,
        "content": "…",
        "input_tokens": 800,
        "output_tokens": 250,
        "cost_usd": 0.000182,
        "response_ms": 850,
        "finish_reason": "stop"
      }
    }
  }
  ```

  Si un modèle a planté, son entrée est `{"ok": false, "error":
  "<reason>"}` — les autres sont indépendants. Pas de tout-ou-rien.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.AI.Ingestion.{Models, Runner}
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/admin/ai/models
  def list_models(conn, _params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_admin(conn, user) do
      payload = Enum.map(Models.list(), &model_summary/1)
      json(conn, %{data: payload, default_id: Models.default_id()})
    else
      %Plug.Conn{} = halted -> halted
    end
  end

  # POST /api/v1/admin/ai/compare-ingestion
  def compare(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_admin(conn, user),
         {:ok, model_ids} <- fetch_model_ids(params),
         {:ok, messages} <- fetch_messages(params) do
      opts =
        []
        |> maybe_put(params, "max_tokens", :max_tokens)
        |> maybe_put(params, "temperature", :temperature)

      results =
        Runner.run_many(model_ids, messages, opts)
        |> Enum.into(%{}, fn {id, result} -> {id, serialize_result(result)} end)

      json(conn, %{results: results})
    else
      %Plug.Conn{} = halted ->
        halted

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp authorize_admin(_conn, %{role: :super_admin}), do: :ok

  defp authorize_admin(conn, _user) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Réservé super_admin"})
    |> halt()
  end

  defp fetch_model_ids(%{"model_ids" => ids}) when is_list(ids) and ids != [] do
    cond do
      not Enum.all?(ids, &is_binary/1) ->
        {:error, "model_ids: doit être une liste de chaînes"}

      Enum.any?(ids, &is_nil(Models.get(&1))) ->
        unknown = Enum.filter(ids, &is_nil(Models.get(&1)))
        {:error, "Modèle(s) inconnu(s) : #{Enum.join(unknown, ", ")}"}

      true ->
        {:ok, ids}
    end
  end

  defp fetch_model_ids(_), do: {:error, "model_ids: requis (liste non vide)"}

  defp fetch_messages(%{"messages" => msgs}) when is_list(msgs) and msgs != [] do
    if Enum.all?(msgs, &valid_message?/1) do
      normalized = Enum.map(msgs, &Map.take(&1, ["role", "content"]))
      normalized = Enum.map(normalized, fn m -> %{role: m["role"], content: m["content"]} end)
      {:ok, normalized}
    else
      {:error, "messages: chaque entrée doit avoir un role + content (string)"}
    end
  end

  defp fetch_messages(_), do: {:error, "messages: requis (liste non vide)"}

  defp valid_message?(%{"role" => r, "content" => c}) when is_binary(r) and is_binary(c) do
    r in ["system", "user", "assistant"]
  end

  defp valid_message?(_), do: false

  defp maybe_put(opts, params, key, atom_key) do
    case Map.get(params, key) do
      nil -> opts
      v -> Keyword.put(opts, atom_key, v)
    end
  end

  defp serialize_result({:ok, res}) do
    %{
      ok: true,
      content: res.content,
      input_tokens: res.input_tokens,
      output_tokens: res.output_tokens,
      cost_usd: res.cost_usd,
      response_ms: res.response_ms,
      finish_reason: Map.get(res, :finish_reason)
    }
  end

  defp serialize_result({:error, reason}) do
    %{ok: false, error: format_error(reason)}
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_error({tag, status, _body}) when is_atom(tag),
    do: "#{tag}: HTTP #{status}"

  defp format_error({tag, payload}) when is_atom(tag),
    do: "#{tag}: #{inspect(payload)}"

  defp format_error(other), do: inspect(other)

  defp model_summary(m) do
    %{
      id: m.id,
      label: m.label,
      provider: m.provider,
      input_per_million_usd: m.input_per_million_usd,
      output_per_million_usd: m.output_per_million_usd,
      context_window: m.context_window,
      notes: m.notes
    }
  end
end
