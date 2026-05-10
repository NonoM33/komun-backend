defmodule KomunBackend.Organizations do
  @moduledoc """
  Context pour les organisations clientes (syndic, autonome).

  Pour l'instant, ne contient que `list_for_staff/1`, utilisée par le
  portail Komun staff (TICKET-2.3). Le reste (création, suspension,
  vue 360, billing) arrive avec les tickets EPIC-2 / EPIC-3 / EPIC-6.
  """

  import Ecto.Query

  alias KomunBackend.Accounts.User
  alias KomunBackend.Organizations.Organization
  alias KomunBackend.Repo
  alias KomunBackend.Residences.Residence

  @plans Ecto.Enum.values(Organization, :subscription_plan)
  @types Ecto.Enum.values(Organization, :type)

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

  @doc "Liste des types d'organisation valides."
  @spec valid_types() :: [atom()]
  def valid_types, do: @types

  @doc """
  TICKET-2.5 — Crée une organisation cliente sales-led + onboarde son
  manager principal (rôle `:syndic_manager`) en une transaction.

  Renvoie `{:ok, %{organization, primary_manager}}` ou un tuple d'erreur
  parmi :

  - `{:error, :primary_manager_required}` si la map manager manque
  - `{:error, :invalid_plan}` si plan inconnu
  - `{:error, :invalid_type}` si type inconnu
  - `{:error, :user_belongs_to_another_org}` si l'email manager est
    déjà rattaché à une autre org (le CSM doit le contacter manuellement
    pour résoudre)
  - `{:error, %Ecto.Changeset{}}` pour les erreurs de validation
    classiques (name manquant, email invalide, etc.)

  ## Exemples

      iex> Organizations.create_with_manager(%{
      ...>   "name" => "Résidence des Tilleuls",
      ...>   "type" => "syndic",
      ...>   "billing_email" => "billing@syndic.com",
      ...>   "plan" => "pro",
      ...>   "primary_manager" => %{
      ...>     "email" => "marc@syndic.com",
      ...>     "first_name" => "Marc"
      ...>   }
      ...> })
      {:ok, %{organization: %Organization{...}, primary_manager: %User{...}}}
  """
  @spec create_with_manager(map()) ::
          {:ok, %{organization: %Organization{}, primary_manager: %User{}}}
          | {:error, atom()}
          | {:error, Ecto.Changeset.t()}
  def create_with_manager(attrs) when is_map(attrs) do
    with {:ok, manager_attrs} <- extract_manager(attrs),
         :ok <- validate_plan(Map.get(attrs, "plan")),
         :ok <- validate_type(Map.get(attrs, "type")) do
      Repo.transaction(fn ->
        case do_create_with_manager(attrs, manager_attrs) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_result()
    end
  end

  defp do_create_with_manager(attrs, manager_attrs) do
    with {:ok, existing_or_nil} <- lookup_existing_manager(manager_attrs),
         :ok <- ensure_no_other_org(existing_or_nil),
         {:ok, org} <- insert_organization(attrs),
         {:ok, manager} <- upsert_manager(existing_or_nil, manager_attrs, org) do
      {:ok, %{organization: org, primary_manager: manager}}
    end
  end

  defp extract_manager(attrs) do
    case Map.get(attrs, "primary_manager") do
      %{} = m when map_size(m) > 0 -> {:ok, m}
      _ -> {:error, :primary_manager_required}
    end
  end

  defp validate_plan(nil), do: :ok
  defp validate_plan(""), do: :ok

  defp validate_plan(plan) when is_binary(plan) do
    if plan in Enum.map(@plans, &Atom.to_string/1) do
      :ok
    else
      {:error, :invalid_plan}
    end
  end

  defp validate_plan(_), do: {:error, :invalid_plan}

  defp validate_type(nil), do: :ok
  defp validate_type(""), do: :ok

  defp validate_type(type) when is_binary(type) do
    if type in Enum.map(@types, &Atom.to_string/1) do
      :ok
    else
      {:error, :invalid_type}
    end
  end

  defp validate_type(_), do: {:error, :invalid_type}

  defp lookup_existing_manager(%{"email" => email}) when is_binary(email) do
    case KomunBackend.Accounts.get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:ok, nil}
      nil -> {:ok, nil}
      %User{} = user -> {:ok, user}
    end
  end

  defp lookup_existing_manager(_), do: {:ok, nil}

  defp ensure_no_other_org(nil), do: :ok
  defp ensure_no_other_org(%User{organization_id: nil}), do: :ok
  defp ensure_no_other_org(%User{}), do: {:error, :user_belongs_to_another_org}

  defp insert_organization(attrs) do
    org_attrs =
      attrs
      |> Map.take(~w(name type plan))
      |> rename_key("plan", "subscription_plan")
      |> maybe_put_billing_email(Map.get(attrs, "billing_email"))

    %Organization{}
    |> Organization.changeset(org_attrs)
    |> Repo.insert()
  end

  defp rename_key(map, old, new) do
    case Map.pop(map, old) do
      {nil, m} -> m
      {value, m} -> Map.put(m, new, value)
    end
  end

  defp maybe_put_billing_email(map, nil), do: map
  defp maybe_put_billing_email(map, ""), do: map
  defp maybe_put_billing_email(map, email), do: Map.put(map, "email", email)

  defp upsert_manager(nil, manager_attrs, org) do
    user_attrs =
      manager_attrs
      |> Map.take(~w(email first_name last_name phone))
      |> Map.put("role", "syndic_manager")
      |> Map.put("organization_id", org.id)

    %User{}
    |> User.changeset(user_attrs)
    |> Repo.insert()
  end

  defp upsert_manager(%User{} = existing, manager_attrs, org) do
    user_attrs =
      manager_attrs
      |> Map.take(~w(first_name last_name phone))
      |> Map.put("role", "syndic_manager")
      |> Map.put("organization_id", org.id)

    existing
    |> User.changeset(user_attrs)
    |> Repo.update()
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

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
