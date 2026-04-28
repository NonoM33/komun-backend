defmodule KomunBackend.Doleances do
  @moduledoc """
  Context for collective grievances ("doléances") — complaints that one
  or more residents want to formalize and escalate to the syndic,
  builder, or another third party.

  Differs from incidents in three ways:

    1. **Collective** — other residents can co-sign, attach their own
       evidence, and add a testimony.
    2. **Escalation-oriented** — the workflow is built to produce a
       complete dossier (formal letter + suggested experts) that can be
       sent outside of the copropriété.
    3. **Persistent** — a doléance represents a structural or recurring
       problem, not a one-off service call.

  Every significant action is recorded as a `DoleanceEvent` so that
  residents (copropriétaires only, not locataires) can see the full
  history of what was done on each doléance.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Doleances.{Doleance, DoleanceFile, DoleanceSupport, DoleanceEvent}
  alias KomunBackendWeb.BuildingChannel

  # ── Reads ────────────────────────────────────────────────────────────────

  def list_doleances(building_id, filters \\ %{}) do
    from(d in Doleance,
      where: d.building_id == ^building_id,
      preload: [:author, :files, supports: :user],
      order_by: [desc: d.inserted_at]
    )
    |> apply_filter(:status, filters["status"])
    |> apply_drafts_visibility(filters)
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, :status, v), do: where(q, [d], d.status == ^v)

  # Brouillons cachés par défaut.
  defp apply_drafts_visibility(q, filters) do
    cond do
      filters["status"] == "brouillon" -> q
      filters["include_drafts"] in [true, "true"] -> q
      true -> where(q, [d], d.status != :brouillon)
    end
  end

  def get_doleance!(id) do
    Repo.get!(Doleance, id)
    |> Repo.preload([:author, :files, supports: :user])
  end

  def get_doleance(id), do: Repo.get(Doleance, id)

  @doc """
  Returns the event timeline for a doléance, ordered chronologically.
  Each event includes the actor (user who triggered it).
  Visible to all copropriétaires — role filtering is done in the controller.
  """
  def list_events(doleance_id) do
    from(e in DoleanceEvent,
      where: e.doleance_id == ^doleance_id,
      preload: [:actor],
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  # ── Writes ───────────────────────────────────────────────────────────────

  def create_doleance(building_id, author_id, attrs) do
    attrs = Map.merge(attrs, %{"building_id" => building_id, "author_id" => author_id})

    with {:ok, doleance} <- %Doleance{} |> Doleance.changeset(attrs) |> Repo.insert() do
      record_event(doleance.id, author_id, :created, %{})
      doleance = Repo.preload(doleance, [:author, :files, supports: :user])

      # Brouillons : pas de broadcast temps réel — les autres résidents
      # ne doivent voir une doléance qu'après validation admin.
      if doleance.status != :brouillon do
        BuildingChannel.broadcast_doleance(building_id, doleance)
      end

      {:ok, doleance}
    end
  end

  def update_doleance(%Doleance{} = doleance, attrs, actor_id \\ nil) do
    old_status = doleance.status

    with {:ok, updated} <- doleance |> Doleance.changeset(attrs) |> Repo.update() do
      if updated.status != old_status do
        record_event(updated.id, actor_id, :status_change, %{
          from: old_status,
          to: updated.status
        })
      end

      updated = Repo.preload(updated, [:author, :files, supports: :user])
      BuildingChannel.broadcast_doleance(updated.building_id, updated)
      {:ok, updated}
    end
  end

  def delete_doleance(%Doleance{} = doleance) do
    Repo.delete(doleance)
  end

  # ── Files (uploads) ───────────────────────────────────────────────────────

  @doc """
  Attache une pièce jointe (photo / document) à une doléance. Validation
  taille / mime déléguée au controller (cf. `DoleanceController.upload_file/2`).
  """
  def attach_file(doleance_id, %User{} = user, attrs) do
    attrs =
      attrs
      |> normalize_file_attrs()
      |> Map.merge(%{
        "doleance_id" => doleance_id,
        "uploaded_by_id" => user.id
      })

    %DoleanceFile{}
    |> DoleanceFile.changeset(attrs)
    |> Repo.insert()
  end

  def get_file!(id), do: Repo.get!(DoleanceFile, id)

  def delete_file(%DoleanceFile{} = file), do: Repo.delete(file)

  defp normalize_file_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Mark a doléance as escalated — typically called when the syndic /
  builder has been contacted with the AI-generated letter. We keep this
  as a dedicated transition so the UI can reliably show "escalated on
  2026-04-24" rather than inferring it from status + timestamps.
  """
  def escalate(%Doleance{} = doleance, actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, updated} <-
           doleance
           |> Doleance.changeset(%{status: :escalated, escalated_at: now})
           |> Repo.update() do
      record_event(updated.id, actor_id, :escalated, %{
        target_name: doleance.target_name,
        target_kind: doleance.target_kind
      })

      {:ok, updated}
    end
  end

  def resolve(%Doleance{} = doleance, note, actor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, updated} <-
           doleance
           |> Doleance.changeset(%{
             status: :resolved,
             resolved_at: now,
             resolution_note: note
           })
           |> Repo.update() do
      record_event(updated.id, actor_id, :resolved, %{resolution_note: note})
      {:ok, updated}
    end
  end

  def close(%Doleance{} = doleance, actor_id) do
    with {:ok, updated} <-
           doleance
           |> Doleance.changeset(%{status: :closed})
           |> Repo.update() do
      record_event(updated.id, actor_id, :closed, %{})
      {:ok, updated}
    end
  end

  def reject(%Doleance{} = doleance, actor_id) do
    with {:ok, updated} <-
           doleance
           |> Doleance.changeset(%{status: :rejected})
           |> Repo.update() do
      record_event(updated.id, actor_id, :rejected, %{})
      {:ok, updated}
    end
  end

  # ── Co-signatures ────────────────────────────────────────────────────────

  @doc """
  Add or update a user's co-signature on a doléance. Upsert semantics:
  calling twice with the same `{doleance_id, user_id}` updates the
  existing support (comment + photos) instead of raising.
  """
  def upsert_support(doleance_id, user_id, attrs) do
    existing =
      Repo.one(
        from s in DoleanceSupport,
          where: s.doleance_id == ^doleance_id and s.user_id == ^user_id
      )

    attrs =
      attrs
      |> Map.put("doleance_id", doleance_id)
      |> Map.put("user_id", user_id)

    cs =
      (existing || %DoleanceSupport{})
      |> DoleanceSupport.changeset(attrs)

    result = if existing, do: Repo.update(cs), else: Repo.insert(cs)

    with {:ok, support} <- result do
      support = Repo.preload(support, :user)

      if is_nil(existing) do
        user_name =
          if support.user,
            do: "#{support.user.first_name} #{support.user.last_name}" |> String.trim(),
            else: nil

        record_event(doleance_id, user_id, :support_added, %{
          user_name: user_name,
          comment: attrs["comment"]
        })
      end

      broadcast_support_change(doleance_id)
      {:ok, support}
    end
  end

  def remove_support(doleance_id, user_id) do
    Repo.delete_all(
      from s in DoleanceSupport,
        where: s.doleance_id == ^doleance_id and s.user_id == ^user_id
    )

    record_event(doleance_id, user_id, :support_removed, %{})
    broadcast_support_change(doleance_id)
    :ok
  end

  defp broadcast_support_change(doleance_id) do
    case get_doleance(doleance_id) do
      nil ->
        :ok

      d ->
        d = Repo.preload(d, [:author, :files, supports: :user])
        BuildingChannel.broadcast_doleance(d.building_id, d)
    end
  end

  # ── AI helpers ───────────────────────────────────────────────────────────

  @doc """
  Persist the AI-generated letter + expert suggestions on a doléance.
  Called from the AI task after a successful Groq completion.
  """
  def save_ai_letter(%Doleance{} = doleance, letter, model, actor_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, updated} <-
           doleance
           |> Doleance.changeset(%{
             ai_letter: letter,
             ai_letter_generated_at: now,
             ai_model: model
           })
           |> Repo.update() do
      record_event(updated.id, actor_id, :letter_generated, %{ai_model: model})
      {:ok, updated}
    end
  end

  def save_ai_suggestions(%Doleance{} = doleance, suggestions, model, actor_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, updated} <-
           doleance
           |> Doleance.changeset(%{
             ai_expert_suggestions: suggestions,
             ai_suggestions_generated_at: now,
             ai_model: model
           })
           |> Repo.update() do
      record_event(updated.id, actor_id, :experts_suggested, %{ai_model: model})
      {:ok, updated}
    end
  end

  # ── Event logging (private) ───────────────────────────────────────────────

  defp record_event(doleance_id, actor_id, event_type, payload) do
    %DoleanceEvent{}
    |> DoleanceEvent.changeset(%{
      doleance_id: doleance_id,
      actor_id: actor_id,
      event_type: event_type,
      payload: payload
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end
end
