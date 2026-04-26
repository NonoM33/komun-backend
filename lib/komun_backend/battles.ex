defmodule KomunBackend.Battles do
  @moduledoc """
  Contexte « Battles » — tournois à élimination.

  Cycle de vie :
    1. `create_battle/3` crée la Battle + le Vote du round 1 (avec ses N
       options) et planifie le job Oban à `vote.ends_at`.
    2. `AdvanceJob` se réveille à l'expiration : tally, sélection des
       qualifiés (top-2 + ex-aequo), création du round suivant ou
       clôture si dernier round.
    3. `cast_vote/4` permet à un résident de voter — délègue à
       `Votes.respond/3` sur le vote du round courant.

  Le module reste mince : la mécanique de tally vit ici, mais le stockage
  des choix passe par les schémas `Votes.Vote` / `Votes.VoteResponse`
  existants — pas de réinvention.
  """

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Battles.Battle
  alias KomunBackend.Votes
  alias KomunBackend.Votes.{Vote, VoteResponse}
  alias KomunBackend.Buildings.BuildingMember

  @default_round_duration_days 3
  @default_max_rounds 2
  @default_quorum_pct 30

  # Une Battle "finished" peut afficher le gagnant. Tant que la battle
  # est running, le résident voit le current vote et son countdown.
  def list_battles(building_id) do
    from(b in Battle,
      where: b.building_id == ^building_id,
      order_by: [desc: b.inserted_at]
    )
    |> Repo.all()
    |> preload_battles()
  end

  def get_battle!(id) do
    Battle
    |> Repo.get!(id)
    |> preload_battles()
  end

  # Le preload via une query partagée (`from(v in Vote, ...)`) ne scope
  # PAS automatiquement la foreign key — on chargeait du coup tous les
  # Vote de la base au lieu de ceux de la battle. On préfère le preload
  # multi-étape : Repo.preload pose le where(battle_id), puis on raffine
  # les sous-associations options + responses.
  defp preload_battles(battle_or_battles) do
    battle_or_battles
    |> Repo.preload([
      :created_by,
      votes: from(v in Vote, order_by: [asc: v.round_number])
    ])
    |> Repo.preload(votes: [options: :devis, responses: :user])
    |> sort_votes()
  end

  defp sort_votes(list) when is_list(list), do: Enum.map(list, &sort_votes/1)
  defp sort_votes(%Battle{votes: %Ecto.Association.NotLoaded{}} = b), do: b

  defp sort_votes(%Battle{votes: votes} = b) do
    %{b | votes: Enum.sort_by(votes, & &1.round_number)}
  end

  @doc """
  Crée la battle + le vote du round 1 + ses options. `attrs` doit
  contenir au minimum `title` et `options` (liste de maps avec au moins
  `label`).

  Plante si `options` < 2 — sans ça il n'y a pas de bataille.
  """
  def create_battle(building_id, user_id, attrs) do
    attrs = normalize_attrs(attrs)

    options = Map.get(attrs, "options", [])

    cond do
      not is_list(options) or length(options) < 2 ->
        {:error, :need_at_least_two_options}

      true ->
        Repo.transaction(fn ->
          battle_attrs =
            attrs
            |> Map.take([
              "title",
              "description",
              "round_duration_days",
              "max_rounds",
              "quorum_pct"
            ])
            |> Map.merge(%{
              "building_id" => building_id,
              "created_by_id" => user_id,
              "round_duration_days" =>
                Map.get(attrs, "round_duration_days", @default_round_duration_days),
              "max_rounds" => Map.get(attrs, "max_rounds", @default_max_rounds),
              "quorum_pct" => Map.get(attrs, "quorum_pct", @default_quorum_pct)
            })

          with {:ok, battle} <-
                 %Battle{} |> Battle.create_changeset(battle_attrs) |> Repo.insert(),
               {:ok, _vote} <- open_round(battle, 1, options, user_id) do
            get_battle!(battle.id)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  # Crée le Vote du round courant avec ses options, schedule l'Oban job
  # qui fera avancer la battle à expiration.
  defp open_round(%Battle{} = battle, round_number, option_specs, user_id) do
    ends_at =
      DateTime.utc_now()
      |> DateTime.add(battle.round_duration_days * 86_400, :second)
      |> DateTime.truncate(:second)

    options_attrs =
      option_specs
      |> Enum.with_index()
      |> Enum.map(fn {opt, idx} ->
        %{
          "label" => Map.get(opt, "label") || Map.get(opt, :label),
          "position" => idx,
          "attachment_url" => Map.get(opt, "attachment_url") || Map.get(opt, :attachment_url),
          "attachment_filename" =>
            Map.get(opt, "attachment_filename") || Map.get(opt, :attachment_filename),
          "attachment_mime_type" =>
            Map.get(opt, "attachment_mime_type") || Map.get(opt, :attachment_mime_type),
          "attachment_size_bytes" =>
            Map.get(opt, "attachment_size_bytes") || Map.get(opt, :attachment_size_bytes),
          "external_url" => Map.get(opt, "external_url") || Map.get(opt, :external_url)
        }
      end)

    vote_attrs = %{
      "title" => "#{battle.title} — Round #{round_number}",
      "description" => battle.description,
      "vote_type" => "single_choice",
      "ends_at" => ends_at,
      "battle_id" => battle.id,
      "round_number" => round_number,
      "options" => options_attrs
    }

    case Votes.create_vote(battle.building_id, user_id, vote_attrs) do
      {:ok, vote} ->
        schedule_advance(battle.id, ends_at)
        {:ok, vote}

      {:error, _} = err ->
        err
    end
  end

  defp schedule_advance(battle_id, %DateTime{} = scheduled_at) do
    # En test on bypass le scheduling Oban pour ne pas que le job
    # s'exécute immédiatement (Oban est en `:inline` globalement et
    # ignore `scheduled_at`). Les tests appellent `advance_battle!/1`
    # manuellement. Cf. config/test.exs.
    if Application.get_env(:komun_backend, :skip_battle_scheduling, false) do
      :ok
    else
      %{battle_id: battle_id}
      |> KomunBackend.Battles.AdvanceJob.new(scheduled_at: scheduled_at)
      |> Oban.insert()
    end
  end

  @doc """
  Vote pour une option du round courant. Renvoie `{:error, :no_open_round}`
  si la battle est terminée ou si aucun round ouvert (cas théorique :
  l'AdvanceJob n'a pas encore tourné).
  """
  def cast_vote(battle_id, user_id, option_id) do
    battle = get_battle!(battle_id)

    case current_vote(battle) do
      nil ->
        {:error, :no_open_round}

      %Vote{status: :closed} ->
        {:error, :round_closed}

      %Vote{} = vote ->
        # On délègue au contexte Votes pour garder la logique de réponse
        # unifiée (insert_or_update + unique constraint).
        case Repo.get_by(VoteResponse, vote_id: vote.id, user_id: user_id) do
          nil ->
            %VoteResponse{}
            |> VoteResponse.changeset(%{
              vote_id: vote.id,
              user_id: user_id,
              option_id: option_id
            })
            |> Repo.insert()

          existing ->
            existing
            |> VoteResponse.changeset(%{option_id: option_id})
            |> Repo.update()
        end
    end
  end

  def current_vote(%Battle{} = battle) do
    votes =
      case battle.votes do
        %Ecto.Association.NotLoaded{} ->
          Repo.all(
            from(v in Vote,
              where: v.battle_id == ^battle.id,
              order_by: [asc: v.round_number]
            )
          )

        list ->
          list
      end

    Enum.find(votes, &(&1.round_number == battle.current_round))
  end

  # ── Tally & avancement ────────────────────────────────────────────────────

  @doc """
  Cœur du moteur — appelé par l'AdvanceJob. Idempotent : si la battle
  est déjà finished ou si le round courant est déjà closed et que le
  round suivant existe, on no-op (l'Oban peut rejouer un job).
  """
  def advance_battle!(battle_id) do
    battle = get_battle!(battle_id)

    cond do
      battle.status != :running ->
        {:noop, battle}

      true ->
        do_advance(battle)
    end
  end

  defp do_advance(%Battle{} = battle) do
    vote = current_vote(battle)

    cond do
      is_nil(vote) ->
        {:noop, battle}

      vote.status == :closed ->
        {:noop, battle}

      true ->
        # 1) on ferme le round courant
        {:ok, _} = Votes.close_vote(vote)

        # 2) tally les responses
        tally = tally_round(vote)

        # 3) dernier round ? → finished. Sinon → ouvre le round suivant.
        if battle.current_round >= battle.max_rounds do
          finalize(battle, tally)
        else
          start_runoff(battle, tally)
        end
    end
  end

  @doc """
  Renvoie un tally du vote sous la forme :
    %{
      counts: %{option_id => votes_count},
      ordered: [%{option_id, label, votes}, ...] trié desc
    }
  """
  def tally_round(%Vote{} = vote) do
    vote = Repo.preload(vote, [:options, :responses])
    counts = Enum.frequencies_by(vote.responses, & &1.option_id)

    ordered =
      vote.options
      |> Enum.map(fn opt ->
        %{
          option_id: opt.id,
          label: opt.label,
          votes: Map.get(counts, opt.id, 0)
        }
      end)
      |> Enum.sort_by(fn r -> {-r.votes, r.label} end)

    %{counts: counts, ordered: ordered, total: length(vote.responses)}
  end

  defp finalize(battle, tally) do
    winner_label =
      case tally.ordered do
        [%{label: label} | _] -> label
        [] -> nil
      end

    {:ok, updated} =
      battle
      |> Battle.update_changeset(%{
        status: "finished",
        winning_option_label: winner_label
      })
      |> Repo.update()

    {:finished, get_battle!(updated.id)}
  end

  defp start_runoff(battle, tally) do
    qualifiers = qualifiers_for_runoff(tally)

    cond do
      # Cas dégénéré : aucun vote du tout → on clôture en finished
      # avec winner = nil, plutôt que de ré-ouvrir un round vide.
      qualifiers == [] ->
        finalize(battle, tally)

      # Si un seul qualifier (très peu probable : il faudrait que tous
      # les votes soient ex-aequo sauf un), on déclare directement
      # gagnant — pas la peine d'un run-off à 1 candidat.
      length(qualifiers) == 1 ->
        finalize(battle, tally)

      true ->
        next_round = battle.current_round + 1

        option_specs =
          Enum.map(qualifiers, fn q ->
            %{"label" => q.label}
          end)

        with {:ok, _} <- open_round(battle, next_round, option_specs, battle.created_by_id),
             {:ok, updated} <-
               battle
               |> Battle.update_changeset(%{current_round: next_round})
               |> Repo.update() do
          {:advanced, get_battle!(updated.id)}
        end
    end
  end

  # Top-2 + tous les ex-aequo au seuil. Si les 3 premiers ont 5 votes,
  # 5 votes, 5 votes, on garde les 3 (et le finaliste peut aussi avoir
  # 3 candidats au final).
  defp qualifiers_for_runoff(tally) do
    case tally.ordered do
      [] ->
        []

      [_only] ->
        tally.ordered

      [first, second | _rest] ->
        # Seuil = score de la 2e place. On garde tout ce qui est ≥.
        # Ça inclut automatiquement les ex-aequo de la 2e place sans
        # casser le tri.
        threshold = second.votes
        Enum.filter(tally.ordered, &(&1.votes >= threshold))
        |> Enum.uniq_by(& &1.option_id)
        |> case do
          [] -> [first, second]
          list -> list
        end
    end
  end

  # ── Quorum (informationnel V1) ───────────────────────────────────────────

  @doc """
  Calcule le pourcentage de membres actifs ayant participé. La V1
  affiche cette info dans la UI mais ne bloque rien — un round se
  clôture même sans quorum.
  """
  def participation_pct(building_id, vote_count) do
    member_count = active_member_count(building_id)

    cond do
      is_nil(member_count) or member_count == 0 -> 0
      true -> round(vote_count * 100 / member_count)
    end
  end

  defp active_member_count(building_id) do
    from(m in BuildingMember,
      where: m.building_id == ^building_id and m.is_active == true
    )
    |> Repo.aggregate(:count)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
