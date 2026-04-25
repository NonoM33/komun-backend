defmodule KomunBackendWeb.VoteController do
  use KomunBackendWeb, :controller

  alias KomunBackend.{Buildings, Votes}
  alias KomunBackend.Votes.Uploads
  alias KomunBackend.Auth.Guardian

  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]

  # GET /api/v1/buildings/:building_id/votes
  def index(conn, %{"building_id" => building_id}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id) do
      votes = Votes.list_votes(building_id)
      json(conn, %{data: Enum.map(votes, &vote_json(&1, user.id))})
    end
  end

  # GET /api/v1/buildings/:building_id/votes/:id
  def show(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id) do
      vote = Votes.get_vote!(id)
      json(conn, %{data: vote_json(vote, user.id)})
    end
  end

  # POST /api/v1/buildings/:building_id/votes
  #
  # Accepts either JSON (`{ vote: {...} }`) or multipart/form-data with
  # `vote[...]` fields, `options[i][...]` (incl. `options[i][file]`) and
  # `photos[]` / `documents[]` Plug.Upload entries.
  def create(conn, %{"building_id" => building_id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(user),
         {:ok, attrs} <- build_create_attrs(params),
         {:ok, vote} <- Votes.create_vote(building_id, user.id, attrs) do
      conn |> put_status(:created) |> json(%{data: vote_json(vote, user.id)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})

      {:error, reason} when is_binary(reason) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  # POST /api/v1/buildings/:building_id/votes/:id/respond
  #
  # Accepts `{choice: "yes|no|abstain"}` (binary) OR `{option_id: <uuid>}`
  # (single_choice). The context picks the right path based on the vote type.
  def respond(conn, %{"building_id" => building_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_building(conn, building_id) do
      response_params = Map.take(params, ["choice", "option_id"])

      case Votes.respond(id, user.id, response_params) do
        {:ok, _} ->
          vote = Votes.get_vote!(id)
          json(conn, %{data: vote_json(vote, user.id)})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
      end
    end
  end

  # PUT /api/v1/buildings/:building_id/votes/:id/close
  def close(conn, %{"building_id" => building_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)
    with :ok <- authorize_building(conn, building_id),
         :ok <- require_privileged(user) do
      vote = Votes.get_vote!(id)
      case Votes.close_vote(vote) do
        {:ok, _} ->
          updated = Votes.get_vote!(id)
          json(conn, %{data: vote_json(updated, user.id)})
        {:error, _} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "Cannot close vote"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})
    end
  end

  # ── Create attrs builder ──────────────────────────────────────────────────

  defp build_create_attrs(%{"vote" => vote_attrs} = params) when is_map(vote_attrs) do
    base = vote_attrs

    options = save_option_uploads(Map.get(params, "options") || [])
    attachments = save_top_level_uploads(params)

    attrs =
      base
      |> Map.put("options", options)
      |> Map.put("attachments", attachments)

    {:ok, attrs}
  end

  defp build_create_attrs(params) when is_map(params) do
    # Multipart without a `vote` envelope — read top-level fields. Clients
    # that send everything flat are still supported.
    options = save_option_uploads(Map.get(params, "options") || [])
    attachments = save_top_level_uploads(params)

    attrs =
      params
      |> Map.take([
        "title",
        "description",
        "ends_at",
        "is_anonymous",
        "vote_type",
        "project_id",
        "status"
      ])
      |> Map.put("options", options)
      |> Map.put("attachments", attachments)

    {:ok, attrs}
  end

  defp save_option_uploads(options) when is_list(options) do
    options
    |> Enum.with_index()
    |> Enum.map(fn {opt, idx} ->
      file = Map.get(opt, "file")
      base = Map.drop(opt, ["file"]) |> Map.put_new("position", idx)

      case file do
        %Plug.Upload{} = upload ->
          case Uploads.save(upload) do
            {:ok, meta} ->
              Map.merge(base, %{
                "attachment_url" => meta.file_url,
                "attachment_filename" => meta.filename,
                "attachment_mime_type" => meta.mime_type,
                "attachment_size_bytes" => meta.file_size_bytes
              })

            _ ->
              base
          end

        _ ->
          base
      end
    end)
  end

  defp save_option_uploads(_), do: []

  defp save_top_level_uploads(params) do
    photos = save_uploads_list(Map.get(params, "photos"), "photo")
    docs = save_uploads_list(Map.get(params, "documents"), "document")
    photos ++ docs
  end

  defp save_uploads_list(uploads, kind) when is_list(uploads) do
    uploads
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%Plug.Upload{} = upload, idx} ->
        case Uploads.save(upload) do
          {:ok, meta} ->
            [%{
              "kind" => kind,
              "file_url" => meta.file_url,
              "filename" => meta.filename,
              "mime_type" => meta.mime_type,
              "file_size_bytes" => meta.file_size_bytes,
              "position" => idx
            }]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp save_uploads_list(_, _), do: []

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp authorize_building(conn, building_id) do
    user = Guardian.Plug.current_resource(conn)
    if user.role == :super_admin or Buildings.member?(building_id, user.id) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp require_privileged(user) do
    if user.role in @privileged_roles, do: :ok, else: {:error, :unauthorized}
  end

  defp vote_json(vote, current_user_id) do
    tally     = Votes.tally(vote)
    has_voted = Votes.has_voted?(vote.id, current_user_id)

    responses = case vote.responses do
      %Ecto.Association.NotLoaded{} -> []
      r -> r
    end

    my_response = Enum.find(responses, &(&1.user_id == current_user_id))
    option_counts = Votes.option_tally(vote)

    options = case vote.options do
      %Ecto.Association.NotLoaded{} -> []
      list -> list
    end
    attachments = case vote.attachments do
      %Ecto.Association.NotLoaded{} -> []
      list -> list
    end

    %{
      id:           vote.id,
      title:        vote.title,
      description:  vote.description,
      status:       vote.status,
      ends_at:      vote.ends_at,
      is_anonymous: vote.is_anonymous,
      vote_type:    vote.vote_type,
      building_id:  vote.building_id,
      linked_project_id: vote.project_id,
      created_by:   maybe_user(vote.created_by),
      tally:        tally,
      has_voted:    has_voted,
      my_choice:    if(my_response, do: my_response.choice, else: nil),
      my_option_id: if(my_response, do: my_response.option_id, else: nil),
      options:      Enum.map(options, &option_json(&1, option_counts)),
      photo_urls:   attachments |> Enum.filter(&(&1.kind == "photo")) |> Enum.map(&attachment_json/1),
      document_urls: attachments |> Enum.filter(&(&1.kind == "document")) |> Enum.map(&attachment_json/1),
      inserted_at:  vote.inserted_at
    }
  end

  defp option_json(option, counts) do
    %{
      id:                    option.id,
      label:                 option.label,
      position:              option.position,
      is_recommended:        option.is_recommended,
      devis_id:              option.devis_id,
      attachment_url:        option.attachment_url,
      attachment_filename:   option.attachment_filename,
      attachment_mime_type:  option.attachment_mime_type,
      count:                 Map.get(counts, option.id, 0)
    }
  end

  defp attachment_json(att) do
    %{
      id:               att.id,
      kind:             att.kind,
      file_url:         att.file_url,
      filename:         att.filename,
      mime_type:        att.mime_type,
      file_size_bytes:  att.file_size_bytes,
      position:         att.position
    }
  end

  defp maybe_user(nil), do: nil
  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(u) do
    name = if u.first_name && u.last_name, do: "#{u.first_name} #{u.last_name}", else: u.email
    %{id: u.id, name: name}
  end

  defp format_errors(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
