defmodule KomunBackendWeb.ChannelController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Channels}
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/channels
  def index(conn, %{"building_id" => building_id}) do
    with :ok <- authorize_member(conn, building_id) do
      channels = Channels.list_channels(building_id)
      json(conn, %{data: Enum.map(channels, &serialize/1)})
    end
  end

  # POST /api/v1/buildings/:building_id/channels
  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_manager(conn, building_id, user) do
      attrs = extract_attrs(params)

      case Channels.create_channel(building_id, user.id, attrs) do
        {:ok, channel} ->
          conn |> put_status(:created) |> json(%{data: serialize(channel)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  # PUT/PATCH /api/v1/buildings/:building_id/channels/:id
  def update(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_manager(conn, building_id, user) do
      channel = Channels.get_channel!(id)

      case Channels.update_channel(channel, extract_attrs(params)) do
        {:ok, updated} ->
          json(conn, %{data: serialize(updated)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/channels/:id
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_manager(conn, building_id, user) do
      channel = Channels.get_channel!(id)
      {:ok, _} = Channels.delete_channel(channel)
      send_resp(conn, :no_content, "")
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp serialize(c) do
    %{
      id: c.id,
      name: c.name,
      description: c.description,
      visibility: c.visibility,
      is_readonly: c.is_readonly,
      building_id: c.building_id,
      created_by_id: c.created_by_id,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  # Accept both a flat payload ({name, description, ...}) and a nested one
  # ({channel: {...}}) to stay backwards-compatible with the legacy Rails
  # admin UI that shipped the nested shape.
  defp extract_attrs(%{"channel" => attrs}) when is_map(attrs), do: attrs
  defp extract_attrs(params) do
    Map.take(params, ["name", "description", "visibility", "is_readonly"])
  end

  defp authorize_member(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "Forbidden"})
      |> halt()
    end
  end

  defp authorize_manager(conn, building_id, user) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      user.role == :super_admin -> :ok
      user.role in Channels.manager_roles() -> :ok
      member_role in Channels.manager_roles() -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seuls le syndic et le conseil syndical peuvent gérer les canaux."})
        |> halt()
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
