defmodule KomunBackend.Events.EventEmailBlast do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "event_email_blasts" do
    # manual_invite       → l'orga a cliqué sur « Envoyer email aux participants »
    # reminder_j1         → push + email auto envoyé J-1 par EventReminderJob
    # gap_j3              → push smart « il manque X plats » J-3
    # thank_you_j_plus_1  → email post-event « merci » J+1
    field :kind, Ecto.Enum,
      values: [:manual_invite, :reminder_j1, :gap_j3, :thank_you_j_plus_1]

    field :recipient_count, :integer, default: 0
    field :subject, :string
    field :body_preview, :string
    field :triggered_ip, :string
    field :sent_at, :utc_datetime

    belongs_to :event, KomunBackend.Events.Event
    belongs_to :triggered_by, KomunBackend.Accounts.User, foreign_key: :triggered_by_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(blast, attrs) do
    blast
    |> cast(attrs, [
      :event_id,
      :triggered_by_id,
      :kind,
      :recipient_count,
      :subject,
      :body_preview,
      :triggered_ip,
      :sent_at
    ])
    |> validate_required([:event_id, :kind])
    |> put_default_sent_at()
  end

  defp put_default_sent_at(cs) do
    case get_field(cs, :sent_at) do
      nil -> put_change(cs, :sent_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> cs
    end
  end
end
