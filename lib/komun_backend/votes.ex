defmodule KomunBackend.Votes do
  @moduledoc "Votes context — scoped by building."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Votes.{Vote, VoteResponse, VoteOption}
  alias KomunBackend.Projects.Project
  alias KomunBackendWeb.VotesChannel

  # Les rounds de battle sont aussi stockés dans `votes` (avec `battle_id`
  # posé). On les exclut ici parce que `/votes/:id` ne sait pas les
  # afficher proprement — ils doivent être vus via `/battles/:id`. Sinon
  # ils polluent l'Activité récente du dashboard avec des entrées
  # « test — Round 2 » qui mènent dans le mur.
  def list_votes(building_id) do
    from(v in Vote,
      where: v.building_id == ^building_id and is_nil(v.battle_id),
      preload: [:created_by, :options, :attachments, :responses],
      order_by: [desc: v.inserted_at]
    )
    |> Repo.all()
  end

  def get_vote!(id) do
    Repo.get!(Vote, id)
    |> Repo.preload([:created_by, :options, :attachments, responses: :user])
  end

  @doc """
  Creates a vote with optional options + attachments + project linking.

  `attrs` may contain string- OR atom-keyed entries. Two extras besides the
  Vote schema fields:

  - `options`        — list of maps, each accepted by `VoteOption.changeset/2`
  - `attachments`    — list of maps already containing `file_url` etc.
                        (the controller saves the `Plug.Upload`s before calling
                         this function so we stay storage-agnostic here)
  - `project_id`     — when set, the parent project is linked back via
                        `projects.vote_id` in the same transaction.
  """
  def create_vote(building_id, user_id, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put("building_id", building_id)
      |> Map.put("created_by_id", user_id)

    result =
      Repo.transaction(fn ->
        changeset = Vote.changeset(%Vote{}, attrs)

        case Repo.insert(changeset) do
          {:ok, vote} ->
            maybe_link_project(vote)
            get_vote!(vote.id)

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)

    with {:ok, vote} <- result do
      VotesChannel.broadcast_vote_created(vote.building_id, build_broadcast_payload(vote))
    end

    result
  end

  # When the new vote points at a project, set `projects.vote_id` so the
  # project page links back. We don't touch project status — that's still the
  # job of `start_vote` for the project-driven flow.
  defp maybe_link_project(%Vote{project_id: nil}), do: :ok

  defp maybe_link_project(%Vote{project_id: project_id, id: vote_id}) do
    case Repo.get(Project, project_id) do
      nil ->
        :ok

      project ->
        project
        |> Ecto.Changeset.change(vote_id: vote_id)
        |> Repo.update()
    end
  end

  def close_vote(vote) do
    result =
      vote
      |> Ecto.Changeset.change(status: :closed)
      |> Repo.update()

    with {:ok, closed} <- result do
      reloaded = get_vote!(closed.id)
      VotesChannel.broadcast_vote_updated(reloaded.building_id, build_broadcast_payload(reloaded))
    end

    result
  end

  @doc """
  Records (or updates) a user's response.

  Accepts either:
  - `%{"choice" => "yes" | "no" | "abstain"}` for binary votes
  - `%{"option_id" => uuid}` for single_choice votes

  Validates that the chosen option actually belongs to the vote.
  """
  def respond(vote_id, user_id, params) when is_map(params) do
    vote = Repo.get!(Vote, vote_id)

    case build_response_attrs(vote, params) do
      {:ok, attrs} ->
        upsert_response(vote_id, user_id, attrs)

      {:error, msg} ->
        cs =
          %VoteResponse{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:base, msg)

        {:error, cs}
    end
  end

  # ── Backwards-compat with the old controller call (single arg) ──
  def respond(vote_id, user_id, choice) when is_binary(choice) or is_atom(choice) do
    respond(vote_id, user_id, %{"choice" => to_string(choice)})
  end

  defp build_response_attrs(%Vote{vote_type: "single_choice", id: vote_id}, %{} = params) do
    case Map.get(params, "option_id") || Map.get(params, :option_id) do
      nil ->
        {:error, "option_id is required for single_choice votes"}

      option_id ->
        case Repo.get(VoteOption, option_id) do
          %VoteOption{vote_id: ^vote_id} ->
            {:ok, %{vote_id: vote_id, option_id: option_id}}

          _ ->
            {:error, "option does not belong to this vote"}
        end
    end
  end

  defp build_response_attrs(%Vote{id: vote_id}, %{} = params) do
    choice = Map.get(params, "choice") || Map.get(params, :choice)

    cond do
      choice in ["yes", "no", "abstain", :yes, :no, :abstain] ->
        {:ok, %{vote_id: vote_id, choice: choice}}

      true ->
        {:error, "choice is required (yes / no / abstain)"}
    end
  end

  defp upsert_response(vote_id, user_id, attrs) do
    base = Map.merge(attrs, %{vote_id: vote_id, user_id: user_id})

    result =
      case Repo.get_by(VoteResponse, vote_id: vote_id, user_id: user_id) do
        nil ->
          %VoteResponse{}
          |> VoteResponse.changeset(base)
          |> Repo.insert()

        existing ->
          existing
          |> VoteResponse.changeset(Map.put(base, :choice, Map.get(base, :choice)))
          |> Repo.update()
      end

    with {:ok, _resp} <- result do
      vote = get_vote!(vote_id)
      VotesChannel.broadcast_vote_updated(vote.building_id, build_broadcast_payload(vote))
    end

    result
  end

  # Building-scoped payload — never includes user-specific fields
  # (`user_id`, `responses`, `my_choice`, `has_voted`). Per-user state lives
  # in the REST `GET /votes` response, which the frontend re-fetches on each
  # broadcast via React-Query invalidation.
  defp build_broadcast_payload(%Vote{} = vote) do
    %{
      vote_id: vote.id,
      tally: tally(vote),
      option_counts: option_tally(vote),
      status: vote.status,
      updated_at: DateTime.utc_now()
    }
  end

  def has_voted?(vote_id, user_id) do
    Repo.exists?(
      from(r in VoteResponse,
        where: r.vote_id == ^vote_id and r.user_id == ^user_id
      )
    )
  end

  @doc "Returns the binary tally — 0s for single_choice votes."
  def tally(vote) do
    responses =
      case vote.responses do
        %Ecto.Association.NotLoaded{} -> []
        r -> r
      end

    yes = Enum.count(responses, &(&1.choice == :yes))
    no = Enum.count(responses, &(&1.choice == :no))
    abstain = Enum.count(responses, &(&1.choice == :abstain))
    %{yes: yes, no: no, abstain: abstain, total: length(responses)}
  end

  @doc "Returns a list of `{option_id => count}` for single_choice tallies."
  def option_tally(vote) do
    responses =
      case vote.responses do
        %Ecto.Association.NotLoaded{} -> []
        r -> r
      end

    Enum.reduce(responses, %{}, fn r, acc ->
      case r.option_id do
        nil -> acc
        oid -> Map.update(acc, oid, 1, &(&1 + 1))
      end
    end)
  end

  # Accepts string- or atom-keyed maps and normalizes to string keys
  # (Ecto changesets accept both, but cast_assoc with mixed keys gets
  # confused).
  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_value(v)}
      {k, v} -> {k, normalize_value(v)}
    end)
  end

  defp normalize_value(v) when is_map(v) and not is_struct(v), do: normalize_keys(v)

  defp normalize_value(v) when is_list(v) do
    Enum.map(v, fn
      m when is_map(m) and not is_struct(m) -> normalize_keys(m)
      other -> other
    end)
  end

  defp normalize_value(v), do: v
end
