defmodule KomunBackend.Incidents do
  @moduledoc "Incidents context — scoped by building."

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Incidents.{Incident, IncidentComment}
  alias KomunBackendWeb.BuildingChannel

  def list_incidents(building_id, filters \\ %{}) do
    base =
      from(i in Incident,
        where: i.building_id == ^building_id,
        preload: [:reporter, :assignee, :comments],
        order_by: [desc: i.inserted_at]
      )

    base
    |> apply_filter(:status, filters["status"])
    |> apply_filter(:severity, filters["severity"])
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, :status, v), do: where(q, [i], i.status == ^v)
  defp apply_filter(q, :severity, v), do: where(q, [i], i.severity == ^v)

  def get_incident!(id), do: Repo.get!(Incident, id) |> Repo.preload([:reporter, :assignee, comments: :author])

  def create_incident(building_id, user_id, attrs) do
    attrs = Map.merge(attrs, %{"building_id" => building_id, "reporter_id" => user_id})

    with {:ok, incident} <- %Incident{} |> Incident.changeset(attrs) |> Repo.insert() do
      incident = Repo.preload(incident, [:reporter, :assignee])
      BuildingChannel.broadcast_incident(building_id, incident)
      {:ok, incident}
    end
  end

  def update_incident(incident, attrs) do
    with {:ok, updated} <- incident |> Incident.changeset(attrs) |> Repo.update() do
      updated = Repo.preload(updated, [:reporter, :assignee])
      BuildingChannel.broadcast_incident(updated.building_id, updated)
      {:ok, updated}
    end
  end

  def resolve_incident(incident, note) do
    with {:ok, resolved} <- incident |> Incident.resolve_changeset(note) |> Repo.update() do
      BuildingChannel.broadcast_incident(resolved.building_id, resolved)
      {:ok, resolved}
    end
  end

  def add_comment(incident_id, author_id, attrs) do
    attrs = Map.merge(attrs, %{"incident_id" => incident_id, "author_id" => author_id})
    %IncidentComment{} |> IncidentComment.changeset(attrs) |> Repo.insert()
  end
end
