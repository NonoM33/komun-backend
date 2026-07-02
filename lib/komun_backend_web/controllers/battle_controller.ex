defmodule KomunBackendWeb.BattleController do
  use KomunBackendWeb, :controller

  require Logger

  alias KomunBackend.{Battles, Buildings, Residences}
  alias KomunBackend.Battles.Battle
  alias KomunBackend.Votes.{Uploads, Vote}
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # GET /api/v1/buildings/:building_id/battles
  def index(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      battles = Battles.list_battles(building_id)
      json(conn, %{data: Enum.map(battles, &battle_json(&1, user))})
    end
  end

  # GET /api/v1/residences/:residence_id/battles
  #
  # Renvoie les battles agrégées de TOUS les bâtiments de la résidence
  # dont l'user est membre. Une résidence multi-bâtiments ne doit pas
  # forcer Coralie (membre_cs sur A et B) à switcher de bâtiment dans
  # la sidebar pour voir une battle créée sur un autre bâtiment — c'est
  # exactement ce qui faisait disparaître « Choix des brises vues » côté
  # Bât. B (incident prod 2026-05-25).
  def residence_index(conn, %{"residence_id" => residence_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_residence(conn, residence_id) do
      battles =
        if user.role == :super_admin do
          Battles.list_residence_battles_for_admin(residence_id)
        else
          Battles.list_residence_battles(residence_id, user.id)
        end

      json(conn, %{data: Enum.map(battles, &battle_json(&1, user))})
    end
  end

  # GET /api/v1/buildings/:building_id/battles/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      battle = Battles.get_battle!(id)

      cond do
        battle.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          json(conn, %{data: battle_json(battle, user)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/battles
  #
  # Accepte du JSON (`{ battle: {...} }`) OU du multipart/form-data avec
  # les champs `battle[...]` à plat et `options[i][file]` (Plug.Upload)
  # quand une option transporte une photo. Mirroré sur VoteController
  # pour réutiliser KomunBackend.Votes.Uploads.save/1.
  #
  # Création réservée aux rôles privilégiés (CS + syndic) : un
  # copropriétaire ne lance pas de battle, il ne fait qu'y participer.
  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    # Fix sécurité UX (2026-05-25) : `require_privileged/1` retourne
    # `{:error, :unauthorized}` mais le `with` ne le gérait pas (pas
    # de clause `else`), ce qui faisait fall-through et faisait crasher
    # l'action en 500. Le copro lambda voyait donc « Erreur serveur »
    # au lieu d'un 403 propre — alarmant. La battle n'était pas créée
    # (le `with` n'atteignait pas `Battles.create_battle/3`), donc pas
    # de faille de sécurité — juste UX trompeuse.
    cond do
      not (user.role == :super_admin or Buildings.member?(building_id, user.id)) ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

      user.role not in @privileged_roles ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Seuls les membres du conseil syndical et le syndic peuvent lancer une battle"
        })
        |> halt()

      true ->
        do_create_battle(conn, user, building_id, params)
    end
  end

  defp do_create_battle(conn, user, building_id, params) do
    attrs = build_create_attrs(params)

    case Battles.create_battle(building_id, user.id, attrs) do
      {:ok, %Battle{} = battle} ->
        conn |> put_status(:created) |> json(%{data: battle_json(battle, user)})

      {:error, :need_at_least_two_options} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Une battle exige au moins 2 options"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      {:error, reason} ->
        Logger.error("[battles] create failed building_id=#{building_id}: #{inspect(reason)}")

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Une erreur est survenue"})
    end
  end

  # PATCH /api/v1/buildings/:building_id/battles/:id
  #
  # Pour la V1, le seul champ « modifiable » d'une battle existante
  # est le bâtiment cible (`building_id`) — l'admin a créé la battle
  # sur le mauvais bâtiment par erreur (la FAB « Créer » s'aligne sur
  # le building courant du store) et veut la rebrancher sans détruire
  # les votes déjà recueillis. Le déplacement est gated CS + syndic ;
  # le nouveau bâtiment doit appartenir à la même résidence (vérifié
  # dans `Battles.move_battle/2`).
  def update(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      # cf. authorize_building/2 — `Buildings.member?` + super_admin
      not (user.role == :super_admin or Buildings.member?(building_id, user.id)) ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

      # Move = action privilégiée (CS + syndic + super_admin) — pas
      # question qu'un copropriétaire lambda téléporte la battle du
      # voisin. NB : `require_privileged/1` renvoie `:unauthorized`
      # mais le `with` du reste du module ne le gère pas (bug latent
      # documenté dans le test) ; on inline le check ici.
      user.role not in @privileged_roles ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

      true ->
        battle = Battles.get_battle!(id)

        cond do
          battle.building_id != building_id ->
            conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

          true ->
            attrs = Map.get(params, "battle", params)
            new_building_id = Map.get(attrs, "building_id")

            cond do
              is_nil(new_building_id) or new_building_id == "" ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "building_id requis"})

              true ->
                case Battles.move_battle(id, new_building_id) do
                  {:ok, moved} ->
                    json(conn, %{data: battle_json(moved, user)})

                  {:error, :same_building} ->
                    json(conn, %{data: battle_json(battle, user)})

                  {:error, :different_residence} ->
                    conn
                    |> put_status(:unprocessable_entity)
                    |> json(%{
                      error:
                        "Une battle ne peut être déplacée qu'entre bâtiments d'une même résidence"
                    })

                  {:error, :building_not_found} ->
                    conn |> put_status(:not_found) |> json(%{error: "Bâtiment introuvable"})

                  {:error, %Ecto.Changeset{} = cs} ->
                    conn
                    |> put_status(:unprocessable_entity)
                    |> json(%{errors: format_errors(cs)})

                  {:error, reason} ->
                    Logger.error(
                      "[battles] move failed battle_id=#{id} new_building_id=#{inspect(new_building_id)}: #{inspect(reason)}"
                    )

                    conn
                    |> put_status(:unprocessable_entity)
                    |> json(%{error: "Une erreur est survenue"})
                end
            end
        end
    end
  end

  # POST /api/v1/buildings/:building_id/battles/:id/vote
  # Body :
  #   * `{ "option_id": "uuid" }`          → single_choice (legacy)
  #   * `{ "option_ids": ["uuid", ...] }`  → multiple_choice (battle.vote_mode)
  #                                          ; liste vide = abstention.
  def cast_vote(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      battle = Battles.get_battle!(id)

      cond do
        battle.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          payload = cast_vote_payload(params)

          case Battles.cast_vote(id, user.id, payload) do
            {:ok, _} ->
              fresh = Battles.get_battle!(id)
              json(conn, %{data: battle_json(fresh, user)})

            {:error, :no_open_round} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Aucun round ouvert"})

            {:error, :round_closed} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Le round est clôturé"})

            {:error, :single_choice_expects_one_option} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{
                error:
                  "Cette battle est en mode choix unique — envoie option_id (ou option_ids à 1 élément max)"
              })

            {:error, {:invalid_option_ids, ids}} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{
                error: "Option(s) inconnue(s) pour ce round",
                invalid_option_ids: ids
              })

            {:error, cs} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})
          end
      end
    end
  end

  # Extrait le payload de vote (option unique ou array) du params.
  # On accepte aussi `option_ids` à 1 élément pour les clients multi-savvy.
  defp cast_vote_payload(%{"option_ids" => ids}) when is_list(ids), do: ids
  defp cast_vote_payload(%{"option_id" => id}), do: id
  defp cast_vote_payload(_), do: []

  # DELETE /api/v1/buildings/:building_id/battles/:id
  #
  # Suppression admin d'une battle (créée par erreur, doublon, etc.).
  # Réservée aux rôles privilégiés — un copropriétaire lambda ne peut
  # pas effacer un tournoi auquel il a participé. La suppression
  # cascade vers les rounds + votes + responses (cf. delete_battle/1).
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      not (user.role == :super_admin or Buildings.member?(building_id, user.id)) ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

      user.role not in @privileged_roles ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

      true ->
        battle = Battles.get_battle!(id)

        cond do
          battle.building_id != building_id ->
            conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

          true ->
            case Battles.delete_battle(id) do
              {:ok, _} ->
                send_resp(conn, :no_content, "")

              {:error, reason} ->
                Logger.error("[battles] delete failed battle_id=#{id}: #{inspect(reason)}")

                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "Une erreur est survenue"})
            end
        end
    end
  end

  # POST /api/v1/buildings/:building_id/battles/:id/advance
  # Endpoint admin pour forcer la transition du round courant — utile
  # pour la recette (sinon il faut attendre 3 jours).
  def advance(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    # Même fix sécurité UX que `create/2` — `with` ne hagit pas
    # `{:error, :unauthorized}` proprement, donc on inline les checks
    # pour renvoyer un 403 net.
    cond do
      not (user.role == :super_admin or Buildings.member?(building_id, user.id)) ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()

      user.role not in @privileged_roles ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Réservé au conseil syndical et au syndic"})
        |> halt()

      true ->
        battle = Battles.get_battle!(id)

        cond do
          battle.building_id != building_id ->
            conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

          true ->
            case Battles.advance_battle!(id) do
              {:noop, b} ->
                json(conn, %{data: battle_json(b, user), state: "noop"})

              {:advanced, b} ->
                json(conn, %{data: battle_json(b, user), state: "advanced"})

              {:finished, b} ->
                json(conn, %{data: battle_json(b, user), state: "finished"})
            end
        end
    end
  end

  # ── Create attrs builder ─────────────────────────────────────────────────
  #
  # Deux formes acceptées :
  #
  #   * JSON : `%{"battle" => %{"title" => ..., "options" => [...]}}`. Les
  #     options viennent déjà sérialisées (pas d'upload).
  #
  #   * Multipart : `%{"battle" => %{...}, "options" => [%{"label" => ...,
  #     "file" => %Plug.Upload{}}]}`. On déplace les `file` vers le disque
  #     via Uploads.save/1 puis on enrichit chaque option avec les
  #     attachment_* renvoyés. Les options du multipart vivent au top-level
  #     parce que les fichiers ne peuvent pas être imbriqués dans une chaîne
  #     `battle[options][i][file]` côté Plug.Conn.
  defp build_create_attrs(%{"battle" => battle_attrs} = params) when is_map(battle_attrs) do
    case normalize_options_param(Map.get(params, "options")) do
      [] -> battle_attrs
      list -> Map.put(battle_attrs, "options", save_option_uploads(list))
    end
  end

  defp build_create_attrs(params) when is_map(params) do
    params
  end

  # Plug parse `options[0][label]=...&options[1][label]=...` comme une
  # map indexée par strings (`%{"0" => %{...}, "1" => %{...}}`), pas
  # comme une liste — l'ancien `is_list/1` laissait donc tomber tout le
  # multipart et la création repartait sans options ⇒ "Une battle exige
  # au moins 2 options" alors que l'utilisateur en avait posté 3.
  defp normalize_options_param(list) when is_list(list), do: list

  defp normalize_options_param(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> parse_option_index(k) end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp normalize_options_param(_), do: []

  defp parse_option_index(k) when is_binary(k) do
    case Integer.parse(k) do
      {n, ""} -> n
      _ -> :infinity
    end
  end

  defp parse_option_index(k) when is_integer(k), do: k
  defp parse_option_index(_), do: :infinity

  defp save_option_uploads(options) do
    Enum.map(options, fn opt ->
      file = Map.get(opt, "file")
      base = Map.drop(opt, ["file"])

      case file do
        %Plug.Upload{} = upload ->
          case Uploads.save(upload) do
            {:ok, meta} ->
              Map.merge(base, %{
                "attachment_url" => meta.file_url,
                "attachment_filename" => meta.filename,
                "attachment_mime_type" => meta.mime_type,
                "attachment_size_bytes" => meta.file_size_bytes
              })

            _ ->
              base
          end

        _ ->
          base
      end
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  # Un user est "membre de la résidence" dès qu'il est membre actif
  # d'au moins un de ses bâtiments. On accepte aussi le super_admin pour
  # rester aligné avec `authorize_building/2`.
  defp authorize_residence(conn, residence_id) do
    user = Guardian.Plug.current_resource(conn)

    cond do
      user.role == :super_admin ->
        :ok

      residence_member?(residence_id, user.id) ->
        :ok

      true ->
        conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp residence_member?(residence_id, user_id) do
    Residences.list_user_residences(user_id)
    |> Enum.any?(&(&1.id == residence_id))
  end

  defp require_privileged(user) do
    if user.role in @privileged_roles, do: :ok, else: {:error, :unauthorized}
  end

  # Hot patch (2026-05-25) : on prend l'objet `viewer` complet en plus
  # du `user_id` parce qu'on a besoin du `viewer.role` pour décider si
  # on attache la liste nominale des voteurs sur chaque option (CS et
  # syndic ont droit à la transparence interne ; un copro lambda ne
  # voit que les compteurs anonymes). `user_id` reste utilisé pour
  # marquer la propre option du viewer (`own_option_ids`).
  defp battle_json(%Battle{} = b, viewer) when is_map(viewer) do
    viewer_privileged = viewer.role in @privileged_roles

    votes =
      Enum.map(
        safe_list(b.votes),
        &vote_round_json(&1, viewer.id, b, viewer_privileged)
      )

    %{
      id: b.id,
      title: b.title,
      description: b.description,
      status: b.status,
      round_duration_days: b.round_duration_days,
      max_rounds: b.max_rounds,
      current_round: b.current_round,
      quorum_pct: b.quorum_pct,
      vote_mode: b.vote_mode,
      allow_none: b.allow_none,
      winning_option_label: b.winning_option_label,
      building_id: b.building_id,
      created_by: maybe_user(b.created_by),
      rounds: votes,
      participation_pct:
        case current_vote_responses_count(b) do
          nil -> nil
          n -> Battles.participation_pct(b.building_id, n)
        end,
      inserted_at: b.inserted_at,
      updated_at: b.updated_at
    }
  end

  # Nombre de VOTANTS uniques sur le round courant. En multi-choice
  # un user peut avoir N responses (une par option cochée) — pour le
  # taux de participation il faut compter les user_id distincts, pas
  # les rows. Sinon participation_pct surévalue (et peut dépasser 100%).
  defp current_vote_responses_count(%Battle{} = b) do
    case Battles.current_vote(b) do
      nil ->
        nil

      %Vote{responses: %Ecto.Association.NotLoaded{}} ->
        nil

      %Vote{responses: r} ->
        r |> Enum.map(& &1.user_id) |> Enum.uniq() |> length()
    end
  end

  defp vote_round_json(%Vote{} = v, user_id, battle, viewer_privileged \\ false) do
    options = Enum.map(safe_list(v.options), &option_json/1)
    responses = safe_list(v.responses)
    counts = Enum.frequencies_by(responses, & &1.option_id)

    # Transparence CS (2026-05-25) : les membres du conseil syndical
    # et le syndic ont besoin de voir QUI a voté QUOI pour pouvoir
    # piloter la copro (relancer les abstentionnistes, comprendre les
    # blocages, justifier une décision). Pour un copro lambda on
    # n'expose que les compteurs — pas question de fliquer le voisinage.
    voters_by_option =
      if viewer_privileged do
        responses
        |> Enum.group_by(& &1.option_id)
        |> Map.new(fn {opt_id, rs} ->
          users =
            rs
            |> Enum.map(& &1.user)
            |> Enum.reject(&(&1 == nil or match?(%Ecto.Association.NotLoaded{}, &1)))
            |> Enum.sort_by(&user_sort_key/1)
            |> Enum.map(&voter_json/1)

          {opt_id, users}
        end)
      else
        %{}
      end

    own_option_ids =
      responses
      |> Enum.filter(&(&1.user_id == user_id))
      |> Enum.map(& &1.option_id)
      |> Enum.uniq()

    # `own_option_id` (singulier, legacy) = première option votée par
    # l'user, ou nil. Conservé pour ne pas casser les anciens clients
    # qui ne savent pas lire `own_option_ids`. Le nouveau champ
    # pluriel est la source de vérité pour le multi-choice.
    own_option_id = List.first(own_option_ids)

    # Pour le round courant on cache les compteurs si la battle est
    # configurée comme anonyme — on évite de teaser les résidents avant
    # la fin. V1 : pas de mode anonyme côté battle, donc on expose tout.
    is_current = v.round_number == battle.current_round and battle.status == :running

    # Nb de votants uniques sur ce round (cf. current_vote_responses_count
    # pour le rationnel). En single_choice c'est == length(responses), en
    # multi_choice ça peut être plus petit.
    total_voters =
      responses
      |> Enum.map(& &1.user_id)
      |> Enum.uniq()
      |> length()

    %{
      id: v.id,
      round_number: v.round_number,
      status: v.status,
      ends_at: v.ends_at,
      title: v.title,
      options:
        Enum.map(options, fn o ->
          o
          |> Map.put(:votes, Map.get(counts, o.id, 0))
          |> Map.put(:is_none, o.position == Battles.none_option_position())
          # `voters` est présent UNIQUEMENT pour les viewers privilégiés
          # — cf. `voters_by_option` ci-dessus. Pour un copro lambda,
          # la clé n'apparaît pas du tout dans le JSON (le frontend
          # check sa présence pour décider d'afficher la pile d'avatars).
          |> Map.merge(
            if viewer_privileged,
              do: %{voters: Map.get(voters_by_option, o.id, [])},
              else: %{}
          )
        end),
      total_votes: total_voters,
      own_option_id: own_option_id,
      own_option_ids: own_option_ids,
      is_current: is_current
    }
  end

  defp user_sort_key(u) do
    last = (u.last_name || "") |> String.downcase()
    first = (u.first_name || "") |> String.downcase()
    {last, first, u.email || ""}
  end

  defp voter_json(u) do
    %{
      id: u.id,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }
  end

  defp option_json(o) do
    %{
      id: o.id,
      label: o.label,
      position: o.position,
      attachment_url: o.attachment_url,
      attachment_filename: o.attachment_filename,
      attachment_mime_type: o.attachment_mime_type,
      external_url: o.external_url
    }
  end

  defp safe_list(%Ecto.Association.NotLoaded{}), do: []
  defp safe_list(nil), do: []
  defp safe_list(list), do: list

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u),
    do: %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
