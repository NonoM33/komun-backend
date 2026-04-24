defmodule KomunBackendWeb.ArchivedCouncilVoteController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Archives

  @cs_roles [:president_cs, :membre_cs, :council, :syndic_manager, :syndic_staff]

  # GET /api/v1/council-votes/archived
  # Liste les votes CS historiques importés depuis Rails. Ouvert aux
  # rôles CS + super_admin.
  def index(conn, params) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or user.role in @cs_roles do
      opts =
        case params["residence_id"] do
          nil -> []
          "" -> []
          id -> [residence_id: id]
        end

      votes = Archives.list_council_votes(opts)
      json(conn, %{data: Enum.map(votes, &serialize/1)})
    else
      conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  # POST /api/v1/admin/council-votes/import
  # Super_admin only. Accepte un JSON bulk (forme décrite dans
  # `Archives.import_council_votes/2`). Idempotent via `legacy_id`.
  def import(conn, params) do
    votes = params["votes"] || []
    residence_id = params["residence_id"]

    if is_list(votes) do
      opts = if residence_id in [nil, ""], do: [], else: [residence_id: residence_id]

      {:ok, stats} = Archives.import_council_votes(votes, opts)
      json(conn, %{data: stats})
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "votes must be a list"})
    end
  end

  defp serialize(v) do
    %{
      id: v.id,
      legacy_id: v.legacy_id,
      title: v.title,
      description: v.description,
      vote_type: v.vote_type,
      status: v.status,
      anonymous: v.anonymous,
      options: v.options,
      total_votes: v.total_votes,
      winning_option_text: v.winning_option_text,
      starts_at: v.starts_at,
      ends_at: v.ends_at,
      closed_at: v.closed_at,
      legacy_created_at: v.legacy_created_at,
      residence_id: v.residence_id
    }
  end
end
