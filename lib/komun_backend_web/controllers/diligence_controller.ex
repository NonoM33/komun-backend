defmodule KomunBackendWeb.DiligenceController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Diligences}
  alias KomunBackend.Diligences.{Diligence, Steps}
  alias KomunBackend.Auth.Guardian

  # GET /api/v1/buildings/:building_id/diligences
  def index(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligences = Diligences.list_diligences(building_id, params)
      json(conn, %{data: Enum.map(diligences, &diligence_json/1)})
    end
  end

  # GET /api/v1/buildings/:building_id/diligences/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligence = Diligences.get_diligence!(id)

      if diligence.building_id == building_id do
        json(conn, %{data: diligence_json(diligence)})
      else
        # Garde-fou : un membre du bâtiment A ne doit pas pouvoir
        # piocher dans les diligences du bâtiment B en passant le
        # bon `building_id` dans l'URL et un `id` qui ne lui appartient pas.
        conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()
      end
    end
  end

  # POST /api/v1/buildings/:building_id/diligences
  def create(conn, %{"building_id" => building_id, "diligence" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user),
         {:ok, diligence} <- Diligences.create_diligence(building_id, user, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: diligence_json(diligence)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})
        |> halt()

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
        |> halt()

      # `authorize_privileged/3` renvoie déjà le conn halted en cas
      # d'échec d'autorisation (403 / 401). On le propage tel quel.
      %Plug.Conn{} = halted ->
        halted
    end
  end

  # PATCH /api/v1/buildings/:building_id/diligences/:id
  def update(conn, %{"building_id" => building_id, "id" => id, "diligence" => attrs}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user) do
      diligence = Diligences.get_diligence!(id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Diligences.update_diligence(diligence, attrs) do
            {:ok, updated} ->
              json(conn, %{data: diligence_json(updated)})

            {:error, cs} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})
          end
      end
    end
  end

  # PATCH /api/v1/buildings/:building_id/diligences/:id/steps/:step_number
  def update_step(conn, %{
        "building_id" => building_id,
        "id" => id,
        "step_number" => step_str,
        "step" => attrs
      }) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_privileged(conn, building_id, user),
         {step_number, ""} <- Integer.parse(step_str),
         true <- Steps.valid_number?(step_number) do
      diligence = Diligences.get_diligence!(id)

      cond do
        diligence.building_id != building_id ->
          conn |> put_status(:not_found) |> json(%{error: "Not found"}) |> halt()

        true ->
          case Diligences.update_step(diligence.id, step_number, attrs) do
            {:ok, _step} ->
              fresh = Diligences.get_diligence!(diligence.id)
              json(conn, %{data: diligence_json(fresh)})

            {:error, :not_found} ->
              conn |> put_status(:not_found) |> json(%{error: "Step not found"}) |> halt()

            {:error, cs} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{errors: format_errors(cs)})
          end
      end
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid step_number (must be 1..#{Steps.count()})"})
        |> halt()
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  defp authorize_privileged(conn, building_id, user) do
    cond do
      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"}) |> halt()

      user.role == :super_admin ->
        :ok

      user.role in @privileged_roles ->
        :ok

      Buildings.get_member_role(building_id, user.id) in @privileged_roles ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Seuls le syndic et le conseil syndical peuvent accéder aux diligences."
        })
        |> halt()
    end
  end

  defp diligence_json(%Diligence{} = d) do
    steps =
      case d.steps do
        %Ecto.Association.NotLoaded{} -> []
        steps -> Enum.map(steps, &step_json/1)
      end

    files =
      case d.files do
        %Ecto.Association.NotLoaded{} -> []
        files -> Enum.map(files, &file_json/1)
      end

    %{
      id: d.id,
      title: d.title,
      description: d.description,
      status: d.status,
      source_type: d.source_type,
      source_label: d.source_label,
      saisine_syndic_letter: d.saisine_syndic_letter,
      mise_en_demeure_letter: d.mise_en_demeure_letter,
      building_id: d.building_id,
      linked_incident_id: d.linked_incident_id,
      created_by: maybe_user(d.created_by),
      steps: steps,
      files: files,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end

  defp step_json(s) do
    %{
      id: s.id,
      step_number: s.step_number,
      status: s.status,
      notes: s.notes,
      completed_at: s.completed_at,
      title: Steps.title(s.step_number),
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp file_json(f) do
    %{
      id: f.id,
      step_number: f.step_number,
      kind: f.kind,
      filename: f.filename,
      file_url: f.file_url,
      file_size_bytes: f.file_size_bytes,
      mime_type: f.mime_type,
      uploaded_by_id: f.uploaded_by_id,
      inserted_at: f.inserted_at
    }
  end

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u),
    do: %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name,
      avatar_url: u.avatar_url
    }

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
