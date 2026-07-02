defmodule KomunBackendWeb.OrganizationController do
  @moduledoc """
  Endpoints `/api/v1/organizations/:id` — lecture d'une organisation par
  un de ses membres.

  Authz : l'utilisateur courant doit être membre de l'organisation (voir
  `KomunBackend.Organizations.member?/2`) ou `:super_admin`. Sinon 403.
  Un id inexistant renvoie 404 sans révéler si l'org existe (le check
  d'appartenance vient après la résolution, donc un non-membre reçoit
  403 sur une org réelle et 404 sur un id inconnu — comportement aligné
  sur les autres controllers).
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Organizations

  def show(conn, %{"id" => id}) do
    with_organization(conn, id, fn org ->
      json(conn, %{data: org_json(org)})
    end)
  end

  def buildings(conn, %{"id" => id}) do
    with_organization(conn, id, fn org ->
      org = KomunBackend.Repo.preload(org, :buildings)
      json(conn, %{data: Enum.map(org.buildings, &building_json/1)})
    end)
  end

  # Résout l'org + vérifie l'appartenance, puis exécute `fun` avec l'org.
  # Centralise le gating pour que `show` et `buildings` restent cohérents.
  defp with_organization(conn, id, fun) do
    user = Guardian.Plug.current_resource(conn)

    case Organizations.get_organization(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      org ->
        if user.role == :super_admin or Organizations.member?(user, org) do
          fun.(org)
        else
          conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
        end
    end
  end

  defp org_json(org) do
    %{
      id: org.id,
      name: org.name,
      slug: org.slug,
      type: org.type,
      logo_url: org.logo_url,
      email: org.email,
      phone: org.phone,
      address: org.address,
      subscription_plan: org.subscription_plan,
      is_active: org.is_active,
      inserted_at: org.inserted_at
    }
  end

  defp building_json(building) do
    %{
      id: building.id,
      name: building.name,
      address: building.address,
      city: building.city,
      postal_code: building.postal_code
    }
  end
end
