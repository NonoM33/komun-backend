defmodule KomunBackendWeb.Staff.OrganizationController do
  @moduledoc """
  Endpoints `/api/v1/staff/organizations` — gestion des organisations
  clientes pour le portail Komun staff. Cf. TICKET-2.3 du backlog SaaS.

  Gating : assuré par le plug `RequireKomunStaff` au niveau du scope
  router (TICKET-1.2). Aucun check de tenancy ici — par définition
  les staff voient toutes les orgs.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Organizations

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
end
