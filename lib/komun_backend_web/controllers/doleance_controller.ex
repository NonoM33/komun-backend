defmodule KomunBackendWeb.DoleanceController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Doleances}
  alias KomunBackend.AI.DoleanceDossier
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/doleances
  def index(conn, %{"building_id" => building_id} = params) do
    with :ok <- authorize_building(conn, building_id) do
      doleances = Doleances.list_doleances(building_id, params)
      json(conn, %{data: Enum.map(doleances, &doleance_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/doleances/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    with :ok <- authorize_building(conn, building_id) do
      doleance = Doleances.get_doleance!(id)
      json(conn, %{data: doleance_json(doleance)})
    end
  end

  # POST /api/v1/buildings/:building_id/doleances
  def create(conn, %{"building_id" => building_id, "doleance" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         {:ok, doleance} <- Doleances.create_doleance(building_id, user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: doleance_json(doleance)})
    else
      {:error, changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
    end
  end

  # PUT /api/v1/buildings/:building_id/doleances/:id
  #
  # Edit is limited to the author and privileged members. Résidents
  # lambda can't touch a doléance they didn't open — they should
  # co-sign and add their own testimony instead.
  def update(conn, %{"building_id" => building_id, "id" => id, "doleance" => attrs}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      case Doleances.update_doleance(doleance, attrs) do
        {:ok, updated} -> json(conn, %{data: doleance_json(updated)})
        {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # DELETE /api/v1/buildings/:building_id/doleances/:id
  def delete(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      {:ok, _} = Doleances.delete_doleance(doleance)
      send_resp(conn, :no_content, "")
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/support
  #
  # Upsert the current user's co-signature (comment + optional photos).
  # The frontend calls this both for "je me joins" (empty body) and for
  # "je complète mon témoignage" (body with comment/photos).
  def add_support(conn, params) do
    %{"building_id" => building_id, "doleance_id" => doleance_id} = params
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "support", %{})

    with :ok <- authorize_building(conn, building_id),
         {:ok, _support} <- Doleances.upsert_support(doleance_id, user.id, attrs) do
      doleance = Doleances.get_doleance!(doleance_id)
      json(conn, %{data: doleance_json(doleance)})
    else
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
    end
  end

  # DELETE /api/v1/buildings/:building_id/doleances/:id/support
  def remove_support(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      :ok = Doleances.remove_support(doleance_id, user.id)
      doleance = Doleances.get_doleance!(doleance_id)
      json(conn, %{data: doleance_json(doleance)})
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/generate-letter
  #
  # Privileged members can run the AI letter generator — we don't want
  # any member triggering Groq calls uncontrollably. The author of the
  # doléance is also allowed, since they own the file they built.
  def generate_letter(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(doleance_id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      case DoleanceDossier.generate_letter(doleance) do
        {:ok, updated} -> json(conn, %{data: doleance_json(updated)})
        {:error, :no_ai_key} -> conn |> put_status(:service_unavailable) |> json(%{error: "L'assistant IA est désactivé sur cet environnement."})
        {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: "Génération IA échouée : #{inspect(reason)}"})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/suggest-experts
  def suggest_experts(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(doleance_id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance) do
      case DoleanceDossier.suggest_experts(doleance) do
        {:ok, updated} -> json(conn, %{data: doleance_json(updated)})
        {:error, :no_ai_key} -> conn |> put_status(:service_unavailable) |> json(%{error: "L'assistant IA est désactivé sur cet environnement."})
        {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: "Suggestions IA échouées : #{inspect(reason)}"})
      end
    end
  end

  # POST /api/v1/buildings/:building_id/doleances/:id/escalate
  def escalate(conn, %{"building_id" => building_id, "doleance_id" => doleance_id}) do
    user = Guardian.Plug.current_resource(conn)
    doleance = Doleances.get_doleance!(doleance_id)

    with :ok <- authorize_building(conn, building_id),
         :ok <- authorize_author_or_privileged(conn, building_id, user, doleance),
         {:ok, updated} <- Doleances.escalate(doleance) do
      updated = KomunBackend.Repo.preload(updated, [:author, supports: :user])
      json(conn, %{data: doleance_json(updated)})
    else
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
    end
  end

  # ── Authorization helpers ────────────────────────────────────────────────

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)

    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      conn |> put_status(403) |> json(%{error: "Forbidden"}) |> halt()
    end
  end

  defp authorize_author_or_privileged(conn, building_id, user, doleance) do
    member_role = Buildings.get_member_role(building_id, user.id)

    cond do
      to_string(doleance.author_id) == to_string(user.id) -> :ok
      user.role == :super_admin -> :ok
      user.role in @privileged_roles -> :ok
      member_role in @privileged_roles -> :ok
      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Seul l'auteur ou le conseil / syndic peut modifier cette doléance."})
        |> halt()
    end
  end

  # ── Serialization ────────────────────────────────────────────────────────

  defp doleance_json(d) do
    %{
      id: d.id,
      title: d.title,
      description: d.description,
      category: d.category,
      severity: d.severity,
      status: d.status,
      photo_urls: d.photo_urls,
      document_urls: d.document_urls,
      target_kind: d.target_kind,
      target_name: d.target_name,
      target_email: d.target_email,
      ai_letter: d.ai_letter,
      ai_letter_generated_at: d.ai_letter_generated_at,
      ai_expert_suggestions: d.ai_expert_suggestions,
      ai_suggestions_generated_at: d.ai_suggestions_generated_at,
      ai_model: d.ai_model,
      escalated_at: d.escalated_at,
      resolved_at: d.resolved_at,
      resolution_note: d.resolution_note,
      building_id: d.building_id,
      author: maybe_user(d.author),
      supports: supports_json(d.supports),
      support_count: length(supports_list(d.supports)),
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  defp supports_json(%Ecto.Association.NotLoaded{}), do: []
  defp supports_json(nil), do: []

  defp supports_json(list) when is_list(list) do
    Enum.map(list, fn s ->
      %{
        id: s.id,
        comment: s.comment,
        photo_urls: s.photo_urls,
        user: maybe_user(s.user),
        inserted_at: s.inserted_at,
        updated_at: s.updated_at
      }
    end)
  end

  defp supports_list(%Ecto.Association.NotLoaded{}), do: []
  defp supports_list(nil), do: []
  defp supports_list(l) when is_list(l), do: l

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u) do
    %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
