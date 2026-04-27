defmodule KomunBackend.AI.IncidentRouter do
  @moduledoc """
  Routage AI d'un email entrant vers un dossier d'incident existant ou
  vers la création d'un nouveau.

  Quand un email arrive via webhook (`POST /api/v1/webhooks/inbound_email`),
  on appelle `route/2` avec :

    * l'email parsé (from, subject, body)
    * la liste des incidents **ouverts** (status `:open` ou `:in_progress`)
      du bâtiment

  Le LLM Groq décide :

    * Si l'email parle clairement d'un dossier en cours → `{:append,
      incident_id}` ; le contrôleur ajoute alors un `IncidentComment`
      sur cet incident.
    * Sinon → `:create` ; le contrôleur crée un nouvel incident, puis
      lance `IncidentSummarizer` en mode `:all` pour produire titre +
      description + micro_summary cohérents.

  Sécurité : si la clé Groq manque ou si le LLM renvoie du JSON cassé,
  on tombe en `:create` par défaut — c'est plus sûr de créer un nouveau
  dossier que de polluer un dossier existant par erreur.
  """

  require Logger

  alias KomunBackend.AI

  @system_prompt """
  Tu es l'agent de tri du syndic. Tu reçois UN email entrant et la
  liste des dossiers d'incidents OUVERTS dans la résidence concernée.

  Décide si l'email :

  - **continue un dossier existant** → réponds {"action": "append",
    "incident_id": "<uuid exact d'un incident de la liste>"}.
    Critère : sujet équivalent (mêmes mots-clés) ET interlocuteurs
    cohérents avec l'historique. Ex. un email "Re: Panne ascenseur B"
    rattache au dossier "Ascenseur bâtiment B – pannes répétées".

  - **lance un nouveau dossier** → réponds {"action": "create"}.
    À choisir si aucun dossier ouvert ne correspond clairement, OU si
    l'email mélange plusieurs sujets distincts, OU s'il s'agit d'un
    nouveau problème.

  Réponds **strictement** en JSON, format exact :
  {"action": "append", "incident_id": "..."} OU {"action": "create"}

  Pas de bloc markdown, pas de texte avant/après le JSON.
  """

  @router_max_tokens 200

  @type route_result ::
          {:append, incident_id :: String.t()}
          | :create
          | {:error, term()}

  @doc """
  Décide où placer un email entrant.

    * `email` : map avec au minimum `:from`, `:subject`, `:body`.
    * `open_incidents` : liste de structs Incident (preload pas nécessaire).
  """
  @spec route(map(), [struct()]) :: route_result()
  def route(email, open_incidents) do
    if System.get_env("GROQ_API_KEY") in [nil, ""] do
      Logger.info("[router] no Groq key — defaulting to :create")
      :create
    else
      case do_route(email, open_incidents) do
        {:ok, result} ->
          result

        {:error, reason} ->
          Logger.warning("[router] failed: #{inspect(reason)} — defaulting to :create")
          :create
      end
    end
  end

  defp do_route(email, []) do
    # Pas de dossier ouvert → on crée d'office, sans appel Groq.
    {:ok, :create}
  end

  defp do_route(email, open_incidents) do
    user_prompt = build_user_prompt(email, open_incidents)

    messages = [
      %{role: :system, content: @system_prompt},
      %{role: :user, content: user_prompt}
    ]

    case AI.Groq.complete(messages,
           max_tokens: @router_max_tokens,
           temperature: 0.0
         ) do
      {:ok, %{content: content}} ->
        case parse_action(content, open_incidents) do
          {:ok, _} = ok -> ok
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp build_user_prompt(email, open_incidents) do
    incidents_listing =
      open_incidents
      |> Enum.map(fn inc ->
        meta = inc.micro_summary || String.slice(inc.description || "", 0, 200)
        "- id=#{inc.id} | titre=#{inc.title} | sévérité=#{inc.severity} | résumé=#{meta}"
      end)
      |> Enum.join("\n")

    """
    Email entrant :
    - De : #{email[:from] || email["from"]}
    - Sujet : #{email[:subject] || email["subject"]}
    - Corps :
    #{email[:body] || email["body"]}

    Dossiers ouverts (id, titre, résumé court) :
    #{incidents_listing}
    """
  end

  defp parse_action(content, open_incidents) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    with {:ok, json} <- Jason.decode(cleaned) do
      case json do
        %{"action" => "create"} ->
          {:ok, :create}

        %{"action" => "append", "incident_id" => id} ->
          if Enum.any?(open_incidents, fn inc -> to_string(inc.id) == to_string(id) end) do
            {:ok, {:append, id}}
          else
            # Le LLM a halluciné un id. Garde-fou : on crée plutôt que
            # de risquer de polluer un dossier inexistant.
            {:error, :unknown_incident_id}
          end

        _ ->
          {:error, :bad_payload}
      end
    end
  end
end
