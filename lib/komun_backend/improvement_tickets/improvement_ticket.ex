defmodule KomunBackend.ImprovementTickets.ImprovementTicket do
  @moduledoc """
  Ticket de feedback produit : un utilisateur signale un bug, propose
  une amélioration ou pose une question. Reçu par l'équipe Komun
  (super_admin), visible aussi par son auteur dans `/ameliorations`.

  Ressource globale — pas de scope `building_id` côté autorisations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:bug, :improvement, :idea]
  @statuses [:open, :in_progress, :resolved, :closed]

  schema "improvement_tickets" do
    field :kind, Ecto.Enum, values: @kinds
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :admin_note, :string
    field :screenshot_urls, {:array, :string}, default: []
    field :resolved_at, :utc_datetime

    belongs_to :author, KomunBackend.Accounts.User, foreign_key: :author_id
    belongs_to :building, KomunBackend.Buildings.Building

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc """
  Changeset utilisé à la création par l'auteur. `author_id` et
  `building_id` sont injectés depuis le contexte d'appel, pas le
  payload — on ne les expose pas dans le `cast/3` public.
  """
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:kind, :title, :description, :author_id, :building_id])
    |> validate_required([:kind, :title, :description, :author_id])
    |> validate_length(:title, min: 5, max: 200)
    |> validate_length(:description, min: 5, max: 5_000)
  end

  @doc """
  Changeset utilisé par les routes d'upload / suppression de capture
  d'écran : on ne touche QUE `screenshot_urls`, jamais le reste du
  ticket.
  """
  def screenshots_changeset(ticket, urls) when is_list(urls) do
    cast(ticket, %{screenshot_urls: urls}, [:screenshot_urls])
  end

  @doc """
  Changeset admin : seuls le statut et la note peuvent évoluer après
  création. Le titre / description / kind / auteur sont figés — on
  ne réécrit pas le retour de l'utilisateur.
  """
  def admin_changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:status, :admin_note])
    |> validate_required([:status])
    |> maybe_set_resolved_at()
  end

  defp maybe_set_resolved_at(cs) do
    case get_change(cs, :status) do
      :resolved ->
        if get_field(cs, :resolved_at),
          do: cs,
          else:
            put_change(
              cs,
              :resolved_at,
              DateTime.utc_now() |> DateTime.truncate(:second)
            )

      _ ->
        cs
    end
  end
end
