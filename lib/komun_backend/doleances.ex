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
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Doleances.{Doleance, DoleanceSupport}
  alias KomunBackendWeb.BuildingChannel

  # ── Reads ────────────────────────────────────────────────────────────────

  def list_doleances(building_id, filters \\ %{}) do
    from(d in Doleance,
      where: d.building_id == ^building_id,
      preload: [:author, supports: :user],
      order_by: [desc: d.inserted_at]
    )
    |> apply_filter(:status, filters["status"])
    |> Repo.all()
  end

  defp apply_filter(q, _field, nil), do: q
  defp apply_filter(q, :status, v), do: where(q, [d], d.status == ^v)

  def get_doleance!(id) do
    Repo.get!(Doleance, id)
    |> Repo.preload([:author, supports: :user])
  end

  def get_doleance(id), do: Repo.get(Doleance, id)

  # ── Writes ───────────────────────────────────────────────────────────────

  def create_doleance(building_id, author_id, attrs) do
    attrs = Map.merge(attrs, %{"building_id" => building_id, "author_id" => author_id})

    with {:ok, doleance} <- %Doleance{} |> Doleance.changeset(attrs) |> Repo.insert() do
      doleance = Repo.preload(doleance, [:author, supports: :user])
      BuildingChannel.broadcast_doleance(building_id, doleance)
      {:ok, doleance}
    end
  end

  def update_doleance(%Doleance{} = doleance, attrs) do
    with {:ok, updated} <- doleance |> Doleance.changeset(attrs) |> Repo.update() do
      updated = Repo.preload(updated, [:author, supports: :user])
      BuildingChannel.broadcast_doleance(updated.building_id, updated)
      {:ok, updated}
    end
  end

  def delete_doleance(%Doleance{} = doleance) do
    Repo.delete(doleance)
  end

  @doc """
  Mark a doléance as escalated — typically called when the syndic /
  builder has been contacted with the AI-generated letter. We keep this
  as a dedicated transition so the UI can reliably show "escalated on
  2026-04-24" rather than inferring it from status + timestamps.
  """
  def escalate(%Doleance{} = doleance) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    doleance
    |> Doleance.changeset(%{status: :escalated, escalated_at: now})
    |> Repo.update()
  end

  def resolve(%Doleance{} = doleance, note) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    doleance
    |> Doleance.changeset(%{
      status: :resolved,
      resolved_at: now,
      resolution_note: note
    })
    |> Repo.update()
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
      broadcast_support_change(doleance_id)
      {:ok, support}
    end
  end

  def remove_support(doleance_id, user_id) do
    Repo.delete_all(
      from s in DoleanceSupport,
        where: s.doleance_id == ^doleance_id and s.user_id == ^user_id
    )

    broadcast_support_change(doleance_id)
    :ok
  end

  defp broadcast_support_change(doleance_id) do
    case get_doleance(doleance_id) do
      nil ->
        :ok

      d ->
        d = Repo.preload(d, [:author, supports: :user])
        BuildingChannel.broadcast_doleance(d.building_id, d)
    end
  end

  # ── AI helpers ───────────────────────────────────────────────────────────

  @doc """
  Persist the AI-generated letter + expert suggestions on a doléance.
  Called from the AI task after a successful Groq completion.
  """
  def save_ai_letter(%Doleance{} = doleance, letter, model) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    doleance
    |> Doleance.changeset(%{
      ai_letter: letter,
      ai_letter_generated_at: now,
      ai_model: model
    })
    |> Repo.update()
  end

  def save_ai_suggestions(%Doleance{} = doleance, suggestions, model) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    doleance
    |> Doleance.changeset(%{
      ai_expert_suggestions: suggestions,
      ai_suggestions_generated_at: now,
      ai_model: model
    })
    |> Repo.update()
  end
end
