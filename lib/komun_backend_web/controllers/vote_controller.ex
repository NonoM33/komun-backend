defmodule KomunBackendWeb.VoteController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Votes}
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # GET /api/v1/buildings/:building_id/votes
  def index(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id) do
      votes = Votes.list_votes(building_id)
      json(conn, %{data: Enum.map(votes, &vote_json(&1, user.id))})
    end
  end

  # GET /api/v1/buildings/:building_id/votes/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id) do
      vote = Votes.get_vote!(id)
      json(conn, %{data: vote_json(vote, user.id)})
    end
  end

  # POST /api/v1/buildings/:building_id/votes
  def create(conn, %{"building_id" => building_id, "vote" => attrs}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(user),
         {:ok, vote} <- Votes.create_vote(building_id, user.id, attrs) do
      conn |> put_status(:created) |> json(%{data: vote_json(vote, user.id)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})
      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # POST /api/v1/buildings/:building_id/votes/:id/respond
  def respond(conn, %{"building_id" => building_id, "id" => id, "choice" => choice}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id) do
      case Votes.respond(id, user.id, choice) do
        {:ok, _} ->
          vote = Votes.get_vote!(id)
          json(conn, %{data: vote_json(vote, user.id)})
        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # PUT /api/v1/buildings/:building_id/votes/:id/close
  def close(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(user) do
      vote = Votes.get_vote!(id)
      case Votes.close_vote(vote) do
        {:ok, _} ->
          updated = Votes.get_vote!(id)
          json(conn, %{data: vote_json(updated, user.id)})
        {:error, _} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "Cannot close vote"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)
    if Buildings.member?(building_id, user.id), do: :ok, else: {:error, :unauthorized}
  end

  defp require_privileged(user) do
    if user.role in @privileged_roles, do: :ok, else: {:error, :unauthorized}
  end

  defp vote_json(vote, current_user_id) do
    tally     = Votes.tally(vote)
    has_voted = Votes.has_voted?(vote.id, current_user_id)
    my_response = Enum.find(
      (case vote.responses do %Ecto.Association.NotLoaded{} -> []; r -> r end),
      &(&1.user_id == current_user_id)
    )

    %{
      id:           vote.id,
      title:        vote.title,
      description:  vote.description,
      status:       vote.status,
      ends_at:      vote.ends_at,
      is_anonymous: vote.is_anonymous,
      building_id:  vote.building_id,
      created_by:   maybe_user(vote.created_by),
      tally:        tally,
      has_voted:    has_voted,
      my_choice:    if(my_response, do: my_response.choice, else: nil),
      inserted_at:  vote.inserted_at
    }
  end

  defp maybe_user(nil), do: nil
  defp maybe_user(u) do
    name = if u.first_name && u.last_name, do: "#{u.first_name} #{u.last_name}", else: u.email
    %{id: u.id, name: name}
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
