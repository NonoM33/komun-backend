defmodule KomunBackend.Organizations do
  @moduledoc """
  Context pour les organisations clientes (syndic, autonome).

  Expose `list_for_staff/1` (portail Komun staff, TICKET-2.3) et la
  lecture d'une organisation par un de ses membres (`get_organization/1`,
  `member?/2`). Le reste (création, suspension, vue 360, billing) arrive
  avec les tickets EPIC-2 / EPIC-3 / EPIC-6.
  """

  import Ecto.Query

  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.{Building, BuildingMember}
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo
  alias KomunBackend.Residences.Residence

  @doc """
  Charge une organisation par son id. Renvoie `nil` si l'id est absent /
  malformé (binary_id invalide) ou si aucune ligne ne correspond.
  """
  @spec get_organization(binary()) :: Organization.t() | nil
  def get_organization(id) when is_binary(id) do
    Repo.get(Organization, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  def get_organization(_), do: nil

  @doc """
  Un utilisateur est membre d'une organisation si :

  - son `organization_id` pointe dessus (cas syndic / user org-scopé), OU
  - il a une adhésion active (`BuildingMember`) dans un bâtiment rattaché
    à cette organisation (cas voisin d'une copro gérée par le syndic).

  Le `super_admin` n'est PAS traité ici — c'est un bypass d'autorisation,
  géré à l'appelant, pas une appartenance métier.
  """
  @spec member?(User.t(), Organization.t()) :: boolean()
  def member?(%User{organization_id: org_id}, %Organization{id: org_id})
      when not is_nil(org_id),
      do: true

  def member?(%User{id: user_id}, %Organization{id: org_id}) do
    Repo.exists?(
      from bm in BuildingMember,
        join: b in Building,
        on: b.id == bm.building_id,
        where:
          bm.user_id == ^user_id and bm.is_active == true and
            b.organization_id == ^org_id
    )
  end

  @plans Ecto.Enum.values(Organization, :subscription_plan)

  @default_per_page 25
  @max_per_page 100

  @doc """
  Renvoie la liste des organisations pour le portail staff. Toujours
  paginée. Filtres optionnels : `:plan`, `:is_active`, `:q` (recherche
  par nom). Tri par défaut : `inserted_at desc`.

  Renvoie :

      %{
        entries: [%Organization{...}, ...],
        meta: %{page: 1, per_page: 25, total: 42}
      }

  Chaque entry est augmentée de `:residences_count` et `:members_count`
  (calculés via subquery).

  ## Exemples

      iex> Organizations.list_for_staff(%{plan: :pro})
      iex> Organizations.list_for_staff(%{q: "tilleuls", page: 2, per_page: 10})
  """
  @spec list_for_staff(map()) :: %{entries: [map()], meta: map()}
  def list_for_staff(params) when is_map(params) do
    page = sanitize_page(Map.get(params, :page))
    per_page = sanitize_per_page(Map.get(params, :per_page))

    base = base_query(params)
    total = Repo.aggregate(base, :count, :id)

    entries =
      base
      |> order_by([o], desc: o.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    org_ids = Enum.map(entries, & &1.id)
    counts = aggregate_counts(org_ids)

    decorated =
      Enum.map(entries, fn org ->
        c = Map.get(counts, org.id, %{residences_count: 0, members_count: 0})

        Map.merge(org, %{
          residences_count: c.residences_count,
          members_count: c.members_count
        })
      end)

    %{
      entries: decorated,
      meta: %{page: page, per_page: per_page, total: total}
    }
  end

  @doc "Liste des plans valides — utile pour valider un input controller."
  @spec valid_plans() :: [atom()]
  def valid_plans, do: @plans

  defp base_query(params) do
    Organization
    |> filter_by_plan(Map.get(params, :plan))
    |> filter_by_is_active(Map.get(params, :is_active))
    |> filter_by_query(Map.get(params, :q))
  end

  defp filter_by_plan(q, nil), do: q

  defp filter_by_plan(q, plan) when is_atom(plan),
    do: from(o in q, where: o.subscription_plan == ^plan)

  defp filter_by_is_active(q, nil), do: q

  defp filter_by_is_active(q, value) when is_boolean(value),
    do: from(o in q, where: o.is_active == ^value)

  defp filter_by_query(q, nil), do: q
  defp filter_by_query(q, ""), do: q

  defp filter_by_query(q, query) when is_binary(query) do
    pattern = "%#{String.downcase(query)}%"
    from(o in q, where: fragment("lower(?)", o.name) |> like(^pattern))
  end

  defp aggregate_counts([]), do: %{}

  defp aggregate_counts(org_ids) do
    residences =
      Repo.all(
        from r in Residence,
          where: r.organization_id in ^org_ids,
          group_by: r.organization_id,
          select: {r.organization_id, count(r.id)}
      )
      |> Map.new()

    members =
      Repo.all(
        from u in User,
          where: u.organization_id in ^org_ids,
          group_by: u.organization_id,
          select: {u.organization_id, count(u.id)}
      )
      |> Map.new()

    Enum.reduce(org_ids, %{}, fn id, acc ->
      Map.put(acc, id, %{
        residences_count: Map.get(residences, id, 0),
        members_count: Map.get(members, id, 0)
      })
    end)
  end

  defp sanitize_page(nil), do: 1
  defp sanitize_page(page) when is_integer(page) and page >= 1, do: page
  defp sanitize_page(page) when is_integer(page), do: 1

  defp sanitize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp sanitize_page(_), do: 1

  defp sanitize_per_page(nil), do: @default_per_page

  defp sanitize_per_page(value) when is_integer(value) do
    value |> max(1) |> min(@max_per_page)
  end

  defp sanitize_per_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> sanitize_per_page(n)
      _ -> @default_per_page
    end
  end

  defp sanitize_per_page(_), do: @default_per_page
end
