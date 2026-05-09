defmodule KomunBackendWeb.CommonResourceController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, CommonResources}
  alias KomunBackend.CommonResources.Resource
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/common-resources
  # Tout membre actif du bâtiment voit les ressources actives.
  def index(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, building_id, user) do
      resources = CommonResources.list_resources(building_id)
      json(conn, %{data: Enum.map(resources, &resource_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/common-resources/admin
  # Vue admin : voit aussi les ressources désactivées.
  def index_admin(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_admin(conn, building_id, user) do
      resources = CommonResources.list_all_resources(building_id)
      json(conn, %{data: Enum.map(resources, &resource_json/1)})
    end
  end

  # POST /api/v1/buildings/:building_id/common-resources
  def create(conn, %{"building_id" => building_id, "resource" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_admin(conn, building_id, user),
         {:ok, resource} <- CommonResources.create_resource(building_id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: resource_json(resource)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
        |> halt()

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # PATCH /api/v1/common-resources/:id
  def update(conn, %{"id" => id, "resource" => attrs}) do
    user = Guardian.Plug.current_resource(conn)
    resource = CommonResources.get_resource!(id)

    with :ok <- authorize_admin(conn, resource.building_id, user),
         {:ok, updated} <- CommonResources.update_resource(resource, attrs) do
      json(conn, %{data: resource_json(updated)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  # DELETE /api/v1/common-resources/:id
  def delete(conn, %{"id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    resource = CommonResources.get_resource!(id)

    with :ok <- authorize_admin(conn, resource.building_id, user) do
      {:ok, _} = CommonResources.delete_resource(resource)
      send_resp(conn, :no_content, "")
    end
  end

  # ------------------------------------------------------------------
  # JSON serialization
  # ------------------------------------------------------------------

  defp resource_json(%Resource{} = r) do
    %{
      id: r.id,
      building_id: r.building_id,
      name: r.name,
      description: r.description,
      kind: r.kind,
      advance_notice_hours: r.advance_notice_hours,
      max_duration_hours: r.max_duration_hours,
      allowed_hours_start: r.allowed_hours_start,
      allowed_hours_end: r.allowed_hours_end,
      exclusive: r.exclusive,
      active: r.active,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end

  # ------------------------------------------------------------------
  # Authz
  # ------------------------------------------------------------------

  defp authorize_member(conn, building_id, user) do
    cond do
      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()

      user.role == :super_admin ->
        :ok

      Buildings.member?(building_id, user.id) ->
        :ok

      true ->
        conn |> put_status(:forbidden) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_admin(conn, building_id, user) do
    cond do
      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()

      CommonResources.admin?(building_id, user) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seuls le syndic et l'administrateur peuvent configurer les ressources."})
        |> halt()
    end
  end

  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
