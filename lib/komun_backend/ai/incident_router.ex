defmodule KomunBackend.AI.IncidentRouter do
  @moduledoc """
  Décide si un email entrant continue un dossier d'incident existant
  (`{:append, incident_id}`) ou doit créer un nouveau dossier
  (`:create`).

  Appelé depuis `InboundEmails.ingest_email/3` pour éviter de créer
  N incidents identiques quand l'admin uploade un thread d'emails sur
  le même sujet (ex : 5 emails "Re: Re: Re: Panne ascenseur"
  devraient atterrir sur 1 seul dossier, pas 5).

  Garde-fous :
    * Si Groq down ou clé manquante → `:create` (jamais coller à un
      dossier au pif)
    * Si le LLM hallucine un incident_id inexistant → `:create`
      (jamais polluer un dossier qui n'est pas dans la liste)
  """

  require Logger

  alias KomunBackend.AI.Groq

  @system_prompt """
  Tu es l'agent de tri d'un syndic de copropriété. Tu reçois UN
  email entrant et la liste des dossiers d'incidents OUVERTS du
  bâtiment.

  Décide :

  - **Append** : l'email continue clairement un dossier existant.
    Critères cumulatifs :
      * sujet équivalent (mêmes mots-clés, ex. "ascenseur",
        "chauffage", "fuite", "porte", "trottoir")
      * continuité logique : même problème, même prestataire
        (Otis, Lamy, Nexity…), même bâtiment, même thread Re:/Fwd:
    Réponds : `{"action": "append", "incident_id": "<uuid>"}`

  - **Create** : aucun dossier ouvert ne correspond clairement, OU
    l'email mélange plusieurs sujets distincts, OU c'est un nouveau
    problème.
    Réponds : `{"action": "create"}`

  Réponds STRICTEMENT en JSON valide, sans markdown, sans texte
  autour. Pas de bloc ```json.
  """

  @router_max_tokens 200

  @type route_result ::
          {:append, incident_id :: String.t()}
          | :create

  @doc """
  Décide où placer un email entrant. Renvoie toujours un résultat
  utilisable (jamais d'erreur remontée — fallback sur `:create`).

    * `email` : map avec `:from`, `:subject`, `:body` (atom ou string)
    * `open_incidents` : liste de structs Incident (preload pas nécessaire)
  """
  @spec route(map(), [struct()]) :: route_result()
  def route(email, open_incidents) do
    cond do
      System.get_env("GROQ_API_KEY") in [nil, ""] ->
        Logger.info("[incident_router] no Groq key — defaulting to :create")
        :create

      open_incidents == [] ->
        :create

      true ->
        case do_route(email, open_incidents) do
          {:ok, decision} ->
            decision

          {:error, reason} ->
            Logger.warning("[incident_router] failed: #{inspect(reason)} — defaulting to :create")
            :create
        end
    end
  end

  defp do_route(email, open_incidents) do
    user_prompt = build_user_prompt(email, open_incidents)

    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: user_prompt}
    ]

    model = System.get_env("GROQ_ROUTER_MODEL") || "openai/gpt-oss-120b"

    case Groq.complete(messages,
           model: model,
           temperature: 0.0,
           max_tokens: @router_max_tokens
         ) do
      {:ok, %{content: content}} ->
        parse_decision(content, open_incidents)

      {:error, _} = err ->
        err
    end
  end

  defp build_user_prompt(email, open_incidents) do
    listing =
      open_incidents
      |> Enum.map(&format_incident/1)
      |> Enum.join("\n")

    """
    Email entrant :

    - De : #{get(email, :from)}
    - Sujet : #{get(email, :subject)}
    - Corps (extrait) :
    #{get(email, :body) |> to_string() |> String.slice(0, 1500)}

    Dossiers ouverts (id, titre, sévérité, résumé court) :
    #{listing}
    """
  end

  defp format_incident(inc) do
    summary =
      inc.micro_summary ||
        (inc.description || "") |> to_string() |> String.slice(0, 200)

    "- id=#{inc.id} | titre=#{inc.title} | sévérité=#{inc.severity} | résumé=#{summary}"
  end

  defp parse_decision(content, open_incidents) do
    cleaned =
      content
      |> to_string()
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```$/, "")

    with {:ok, json} <- decode_json(cleaned) do
      case json do
        %{"action" => "create"} ->
          {:ok, :create}

        %{"action" => "append", "incident_id" => id} when is_binary(id) ->
          if Enum.any?(open_incidents, fn inc -> to_string(inc.id) == id end) do
            {:ok, {:append, id}}
          else
            # Le LLM a halluciné un id qui n'est pas dans la liste.
            # On ne risque pas de polluer un dossier inexistant : create.
            {:error, :unknown_incident_id}
          end

        _ ->
          {:error, :bad_payload}
      end
    end
  end

  # Tolère les réponses LLM avec texte avant/après l'objet JSON.
  defp decode_json(content) do
    with {:error, _} <- Jason.decode(content) do
      case Regex.run(~r/\{(?:[^{}]|\{[^{}]*\})*\}/s, content) do
        [match] -> Jason.decode(match)
        _ -> {:error, :no_json_found}
      end
    end
  end

  defp get(email, key) do
    str_key = Atom.to_string(key)
    (email[key] || email[str_key]) |> to_string()
  end
end
