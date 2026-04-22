defmodule KomunBackend.Projects do
  @moduledoc """
  Projects context — copro workflow that groups devis and eventually triggers
  a vote on the chosen devis.

  Scoped by building: every query requires a `building_id` so a member of
  building A can never see building B's projects, even by guessing UUIDs.
  """

  import Ecto.Query

  alias KomunBackend.Repo
  alias KomunBackend.Projects.{Project, Devis}
  alias KomunBackend.Votes

  # ── Projects ────────────────────────────────────────────────────────────

  def list_projects(building_id) do
    from(p in Project,
      where: p.building_id == ^building_id,
      preload: [:created_by, :vote, devis: :uploaded_by],
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  def get_project(building_id, id) do
    from(p in Project,
      where: p.building_id == ^building_id and p.id == ^id,
      preload: [:created_by, :vote, devis: :uploaded_by]
    )
    |> Repo.one()
  end

  def get_project!(building_id, id) do
    case get_project(building_id, id) do
      nil -> raise Ecto.NoResultsError, queryable: Project
      p -> p
    end
  end

  def create_project(building_id, user_id, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.merge(%{"building_id" => building_id, "created_by_id" => user_id})

    with {:ok, p} <- %Project{} |> Project.changeset(attrs) |> Repo.insert() do
      {:ok, get_project!(building_id, p.id)}
    end
  end

  def update_project(%Project{} = project, attrs) do
    with {:ok, p} <- project |> Project.changeset(normalize_keys(attrs)) |> Repo.update() do
      {:ok, get_project!(project.building_id, p.id)}
    end
  end

  def delete_project(%Project{} = project), do: Repo.delete(project)

  @doc """
  Creates a vote on the devis picked by the conseil, flips the project to
  `:voting` and links the two. Returns `{:ok, project}` with the vote
  preloaded.
  """
  def start_vote(%Project{} = project, user_id, devis_id, opts \\ []) do
    devis = Repo.get_by(Devis, id: devis_id, project_id: project.id)

    cond do
      is_nil(devis) ->
        {:error, :devis_not_found}

      project.status == :voting ->
        {:error, :already_voting}

      true ->
        vote_attrs = %{
          "title" => vote_title(project, devis),
          "description" => vote_description(project, devis, opts),
          "ends_at" => Keyword.get(opts, :ends_at)
        }

        Repo.transaction(fn ->
          with {:ok, vote} <- Votes.create_vote(project.building_id, user_id, vote_attrs),
               {:ok, p} <-
                 update_project(project, %{
                   status: :voting,
                   chosen_devis_id: devis.id,
                   vote_id: vote.id
                 }) do
            p
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
    end
  end

  defp vote_title(project, devis),
    do: "Validation devis — #{project.title} (#{devis.vendor_name})"

  defp vote_description(project, devis, opts) do
    price =
      case devis.analysis do
        %{"price_eur" => n} when is_number(n) -> "Montant estimé : #{format_eur(n)}.\n"
        _ -> ""
      end

    intro = Keyword.get(opts, :description, project.description || "")

    """
    Le conseil propose de retenir le devis de #{devis.vendor_name} pour le projet « #{project.title} ».
    #{price}#{intro}
    """
    |> String.trim()
  end

  defp format_eur(n) when is_float(n), do: :io_lib.format("~.2f €", [n]) |> IO.iodata_to_binary()
  defp format_eur(n), do: "#{n} €"

  # ── Devis ───────────────────────────────────────────────────────────────

  def list_devis(project_id) do
    from(d in Devis,
      where: d.project_id == ^project_id,
      preload: [:uploaded_by],
      order_by: [asc: d.inserted_at]
    )
    |> Repo.all()
  end

  def get_devis(project_id, id) do
    Repo.get_by(Devis, id: id, project_id: project_id)
    |> case do
      nil -> nil
      d -> Repo.preload(d, :uploaded_by)
    end
  end

  def create_devis(project_id, user_id, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.merge(%{"project_id" => project_id, "uploaded_by_id" => user_id})

    with {:ok, d} <- %Devis{} |> Devis.changeset(attrs) |> Repo.insert() do
      {:ok, Repo.preload(d, :uploaded_by)}
    end
  end

  def update_devis(%Devis{} = devis, attrs) do
    devis |> Devis.changeset(normalize_keys(attrs)) |> Repo.update()
  end

  def delete_devis(%Devis{} = devis), do: Repo.delete(devis)

  # Normalize atom-keyed attrs to string-keyed (Ecto.Changeset.cast accepts
  # either but our controllers mix the two).
  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
