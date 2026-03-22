defmodule KomunBackendWeb.IncidentCommentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Incidents, Auth.Guardian}

  def create(conn, %{"incident_id" => incident_id, "comment" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    case Incidents.add_comment(incident_id, user.id, attrs) do
      {:ok, comment} ->
        conn
        |> put_status(:created)
        |> json(%{data: %{
          id: comment.id,
          body: comment.body,
          is_internal: comment.is_internal,
          incident_id: comment.incident_id,
          inserted_at: comment.inserted_at
        }})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))})
    end
  end
end
