defmodule KomunBackendWeb.Staff.OrganizationController do
  @moduledoc """
  Endpoints `/api/v1/staff/organizations` — gestion des organisations
  clientes pour le portail Komun staff. Cf. TICKET-2.3 du backlog SaaS.

  Gating : assuré par le plug `RequireKomunStaff` au niveau du scope
  router (TICKET-1.2). Aucun check de tenancy ici — par définition
  les staff voient toutes les orgs.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Accounts
  alias KomunBackend.Organizations
  alias KomunBackend.Residences

  def index(conn, params) do
    case build_filters(params) do
      {:ok, filters} ->
        result = Organizations.list_for_staff(filters)
        json(conn, %{data: Enum.map(result.entries, &org_summary_json/1), meta: result.meta})

      {:error, :invalid_plan} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "invalid_plan",
          allowed: Enum.map(Organizations.valid_plans(), &Atom.to_string/1)
        })

      {:error, :invalid_is_active} ->
        conn
        |> put_status(422)
        |> json(%{error: "invalid_is_active", allowed: ["true", "false"]})
    end
  end

  defp build_filters(params) do
    with {:ok, plan} <- parse_plan(Map.get(params, "plan")),
         {:ok, is_active} <- parse_is_active(Map.get(params, "is_active")) do
      filters =
        %{
          page: Map.get(params, "page"),
          per_page: Map.get(params, "per_page"),
          q: trim(Map.get(params, "q"))
        }
        |> maybe_put(:plan, plan)
        |> maybe_put(:is_active, is_active)

      {:ok, filters}
    end
  end

  @doc """
  TICKET-2.5 — Crée une nouvelle organisation cliente sales-led et
  onboarde son `primary_manager` (rôle `:syndic_manager`). Renvoie
  un magic-link à transmettre manuellement au manager (le mailer
  arrive avec EPIC-12).
  """
  def create(conn, params) do
    case Organizations.create_with_manager(params) do
      {:ok, %{organization: org, primary_manager: manager}} ->
        magic_link = generate_manager_magic_link(manager)

        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            organization: org_full_json(org),
            primary_manager: user_json(manager),
            magic_link: magic_link
          }
        })

      {:error, :primary_manager_required} ->
        conn |> put_status(422) |> json(%{error: "primary_manager_required"})

      {:error, :invalid_plan} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "invalid_plan",
          allowed: Enum.map(Organizations.valid_plans(), &Atom.to_string/1)
        })

      {:error, :invalid_type} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "invalid_type",
          allowed: Enum.map(Organizations.valid_types(), &Atom.to_string/1)
        })

      {:error, :user_belongs_to_another_org} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "user_belongs_to_another_org",
          hint:
            "Cet email est déjà rattaché à une autre organisation. " <>
              "Contactez l'utilisateur pour clarifier avant de continuer."
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  @doc """
  TICKET-6.1 — Provisionne une 1ère résidence (ou une supplémentaire)
  pour une organisation cliente, avec ses bâtiments. Génère les
  `join_code` côté serveur (règle sacrée — cf. CLAUDE.md).

  Renvoie 201 `{data: {residence, buildings}}` avec les join_codes
  pour transmission par le CSM (l'envoi auto par email arrivera avec
  EPIC-12).
  """
  def provision_residence(conn, %{"id" => org_id} = params) do
    case Residences.create_with_buildings(org_id, params) do
      {:ok, %{residence: residence, buildings: buildings}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            residence: residence_full_json(residence),
            buildings: Enum.map(buildings, &building_summary_json/1)
          }
        })

      {:error, :no_buildings_provided} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "no_buildings_provided",
          hint: "Au moins un bâtiment est requis (clé `buildings: [...]`)."
        })

      {:error, :organization_not_found} ->
        conn |> put_status(404) |> json(%{error: "organization_not_found"})

      {:error, :organization_suspended} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "organization_suspended",
          hint: "Réactivez l'organisation avant de provisionner une résidence."
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp residence_full_json(residence) do
    %{
      id: residence.id,
      name: residence.name,
      slug: residence.slug,
      address: residence.address,
      city: residence.city,
      postal_code: residence.postal_code,
      country: residence.country,
      join_code: residence.join_code,
      organization_id: residence.organization_id,
      is_active: residence.is_active,
      inserted_at: residence.inserted_at
    }
  end

  defp building_summary_json(building) do
    %{
      id: building.id,
      name: building.name,
      address: building.address,
      city: building.city,
      postal_code: building.postal_code,
      join_code: building.join_code,
      residence_id: building.residence_id,
      organization_id: building.organization_id
    }
  end

  defp generate_manager_magic_link(manager) do
    case Accounts.create_magic_link(manager.email) do
      {:ok, %{token: token, code: code}} ->
        base = System.get_env("APP_BASE_URL", "https://komun.app")

        %{
          url: "#{base}/auth/verify?token=#{token}",
          code: code,
          email: manager.email,
          expires_in_minutes: 15
        }

      {:error, _} ->
        # Le magic-link n'est pas critique : la création de l'org doit
        # rester un succès. Le staff pourra le regénérer via
        # /admin/users/:id/magic-link.
        nil
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end

  defp parse_plan(nil), do: {:ok, nil}
  defp parse_plan(""), do: {:ok, nil}

  defp parse_plan(value) when is_binary(value) do
    allowed = Enum.map(Organizations.valid_plans(), &Atom.to_string/1)

    if value in allowed do
      {:ok, String.to_existing_atom(value)}
    else
      {:error, :invalid_plan}
    end
  end

  defp parse_is_active(nil), do: {:ok, nil}
  defp parse_is_active(""), do: {:ok, nil}
  defp parse_is_active("true"), do: {:ok, true}
  defp parse_is_active("false"), do: {:ok, false}
  defp parse_is_active(_), do: {:error, :invalid_is_active}

  defp trim(nil), do: nil
  defp trim(s) when is_binary(s), do: String.trim(s)
  defp trim(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp org_summary_json(org) do
    %{
      id: org.id,
      name: org.name,
      slug: org.slug,
      type: org.type,
      subscription_plan: org.subscription_plan,
      subscription_expires_at: org.subscription_expires_at,
      is_active: org.is_active,
      residences_count: Map.get(org, :residences_count, 0),
      members_count: Map.get(org, :members_count, 0),
      inserted_at: org.inserted_at
    }
  end

  defp org_full_json(org) do
    %{
      id: org.id,
      name: org.name,
      slug: org.slug,
      type: org.type,
      siret: org.siret,
      email: org.email,
      phone: org.phone,
      subscription_plan: org.subscription_plan,
      subscription_expires_at: org.subscription_expires_at,
      is_active: org.is_active,
      inserted_at: org.inserted_at
    }
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      first_name: user.first_name,
      last_name: user.last_name,
      role: user.role,
      organization_id: user.organization_id
    }
  end
end
