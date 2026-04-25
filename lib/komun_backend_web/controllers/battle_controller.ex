defmodule KomunBackendWeb.BattleController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Battles, Buildings}
  alias KomunBackend.Battles.Battle
  alias KomunBackend.Votes.Vote
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # GET /api/v1/buildings/:building_id/battles
  def index(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      battles = Battles.list_battles(building_id)
      json(conn, %{data: Enum.map(battles, &battle_json(&1, user.id))})
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
          json(conn, %{data: battle_json(battle, user.id)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/battles
  #
  # Body : { battle: { title, description?, options: [{label, …}, …],
  #          round_duration_days?, max_rounds?, quorum_pct? } }
  #
  # Création réservée aux rôles privilégiés (CS + syndic) : un
  # copropriétaire ne lance pas de battle, il ne fait qu'y participer.
  def create(conn, %{"building_id" => building_id, "battle" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(user) do
      case Battles.create_battle(building_id, user.id, attrs) do
        {:ok, %Battle{} = battle} ->
          conn |> put_status(:created) |> json(%{data: battle_json(battle, user.id)})

        {:error, :need_at_least_two_options} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Une battle exige au moins 2 options"})

        {:error, %Ecto.Changeset{} = cs} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(cs)})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/battles/:id/vote
  # Body : { option_id: "uuid" } — vote pour l'option du round courant.
  def cast_vote(conn, %{"building_id" => building_id, "id" => id, "option_id" => option_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      battle = Battles.get_battle!(id)

      cond do
        battle.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Battles.cast_vote(id, user.id, option_id) do
            {:ok, _} ->
              fresh = Battles.get_battle!(id)
              json(conn, %{data: battle_json(fresh, user.id)})

            {:error, :no_open_round} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Aucun round ouvert"})

            {:error, :round_closed} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Le round est clôturé"})

            {:error, cs} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})
          end
      end
    end
  end

  # POST /api/v1/buildings/:building_id/battles/:id/advance
  # Endpoint admin pour forcer la transition du round courant — utile
  # pour la recette (sinon il faut attendre 3 jours).
  def advance(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(user) do
      battle = Battles.get_battle!(id)

      cond do
        battle.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Battles.advance_battle!(id) do
            {:noop, b} ->
              json(conn, %{data: battle_json(b, user.id), state: "noop"})

            {:advanced, b} ->
              json(conn, %{data: battle_json(b, user.id), state: "advanced"})

            {:finished, b} ->
              json(conn, %{data: battle_json(b, user.id), state: "finished"})
          end
      end
    end
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

  defp require_privileged(user) do
    if user.role in @privileged_roles, do: :ok, else: {:error, :unauthorized}
  end

  defp battle_json(%Battle{} = b, user_id) do
    votes = Enum.map(safe_list(b.votes), &vote_round_json(&1, user_id, b))

    %{
      id: b.id,
      title: b.title,
      description: b.description,
      status: b.status,
      round_duration_days: b.round_duration_days,
      max_rounds: b.max_rounds,
      current_round: b.current_round,
      quorum_pct: b.quorum_pct,
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

  defp current_vote_responses_count(%Battle{} = b) do
    case Battles.current_vote(b) do
      nil -> nil
      %Vote{responses: %Ecto.Association.NotLoaded{}} -> nil
      %Vote{responses: r} -> length(r)
    end
  end

  defp vote_round_json(%Vote{} = v, user_id, battle) do
    options = Enum.map(safe_list(v.options), &option_json/1)
    responses = safe_list(v.responses)
    counts = Enum.frequencies_by(responses, & &1.option_id)

    own_response =
      Enum.find(responses, fn r -> r.user_id == user_id end)
      |> case do
        nil -> nil
        r -> r.option_id
      end

    # Pour le round courant on cache les compteurs si la battle est
    # configurée comme anonyme — on évite de teaser les résidents avant
    # la fin. V1 : pas de mode anonyme côté battle, donc on expose tout.
    is_current = v.round_number == battle.current_round and battle.status == :running

    %{
      id: v.id,
      round_number: v.round_number,
      status: v.status,
      ends_at: v.ends_at,
      title: v.title,
      options:
        Enum.map(options, fn o ->
          Map.put(o, :votes, Map.get(counts, o.id, 0))
        end),
      total_votes: length(responses),
      own_option_id: own_response,
      is_current: is_current
    }
  end

  defp option_json(o) do
    %{
      id: o.id,
      label: o.label,
      position: o.position,
      attachment_url: o.attachment_url,
      attachment_filename: o.attachment_filename,
      attachment_mime_type: o.attachment_mime_type
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
