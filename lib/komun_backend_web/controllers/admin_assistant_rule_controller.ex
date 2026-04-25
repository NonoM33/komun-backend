defmodule KomunBackendWeb.AdminAssistantRuleController do
  @moduledoc """
  Admin CRUD on the per-building AI prompt rules. Lives behind the
  `:require_super_admin` plug so only super_admin can read or mutate
  those rules — they steer the assistant's answers and we treat them
  with the same care as a deployment.
  """

  use KomunBackendWeb, :controller

  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Assistant.{Rule, Rules}

  # GET /api/v1/admin/buildings/:building_id/assistant-rules
  def index(conn, %{"building_id" => building_id}) do
    rules = Rules.list_rules(building_id)
    json(conn, %{data: Enum.map(rules, &rule_json/1)})
  end

  # POST /api/v1/admin/buildings/:building_id/assistant-rules
  def create(conn, %{"building_id" => building_id} = params) do
    actor = Guardian.Plug.current_resource(conn)
    attrs = Map.take(params, ["content", "enabled", "position"])

    case Rules.create_rule(building_id, actor && actor.id, attrs) do
      {:ok, rule} ->
        conn |> put_status(:created) |> json(%{data: rule_json(rule)})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # PATCH /api/v1/admin/buildings/:building_id/assistant-rules/:id
  def update(conn, %{"building_id" => building_id, "id" => id} = params) do
    attrs = Map.take(params, ["content", "enabled", "position"])

    with {:ok, rule} <- Rules.get_rule(id),
         :ok <- ensure_in_building(rule, building_id),
         {:ok, updated} <- Rules.update_rule(rule, attrs) do
      json(conn, %{data: rule_json(updated)})
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Rule not found"})

      {:error, :wrong_building} ->
        conn |> put_status(:not_found) |> json(%{error: "Rule not found"})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # DELETE /api/v1/admin/buildings/:building_id/assistant-rules/:id
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    with {:ok, rule} <- Rules.get_rule(id),
         :ok <- ensure_in_building(rule, building_id),
         {:ok, _} <- Rules.delete_rule(rule) do
      json(conn, %{message: "Rule deleted"})
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Rule not found"})

      {:error, :wrong_building} ->
        conn |> put_status(:not_found) |> json(%{error: "Rule not found"})

      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp ensure_in_building(%Rule{building_id: bid}, building_id) do
    if to_string(bid) == to_string(building_id), do: :ok, else: {:error, :wrong_building}
  end

  defp rule_json(%Rule{} = rule) do
    %{
      id: rule.id,
      building_id: rule.building_id,
      content: rule.content,
      enabled: rule.enabled,
      position: rule.position,
      created_by_user_id: rule.created_by_user_id,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end

  defp format_errors(changeset) when is_struct(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
