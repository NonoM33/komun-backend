defmodule KomunBackend.Incidents.IncidentEmail do
  @moduledoc """
  Une correspondance email rattachée à un incident.

  Trois sources possibles :
  - `:webhook`  → l'email est arrivé sur l'inbox `incident-{id}@…` via Resend
  - `:paste`    → un user a collé un email reçu / envoyé hors-app dans l'UI
  - `:send`     → on l'a émis via Resend depuis l'app

  Et deux directions :
  - `:inbound`  → reçu (paste OU webhook)
  - `:outbound` → envoyé via Resend ; `provider_message_id` permet de matcher
                   les webhooks de delivery (`email.delivered`, `email.opened`,
                   `email.bounced`, …) qui viendront enrichir
                   `delivery_events`.

  Ce schema est append-by-default : on ne réécrit pas un email existant ;
  on ajoute des `delivery_events` au fil de l'eau pour les sortants.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @directions [:inbound, :outbound]
  @sources [:webhook, :paste, :send]
  @statuses [:received, :processing, :processed, :failed, :ignored, :unmatched]
  @classifications [
    :complaint,
    :quote,
    :syndic_note,
    :incident_report,
    :general_info,
    :invoice,
    :spam,
    :other
  ]
  @correspondent_kinds [:syndic, :contractor, :neighbor, :public_admin, :other]

  schema "incident_emails" do
    field :direction, Ecto.Enum, values: @directions, default: :inbound
    field :source, Ecto.Enum, values: @sources, default: :webhook

    field :subject, :string
    field :from_email, :string
    field :from_name, :string
    field :to_email, :string
    field :cc_emails, {:array, :string}, default: []
    field :reply_to, :string
    field :text_body, :string
    field :html_body, :string
    field :raw_text, :string
    field :headers, :map, default: %{}

    field :provider, :string, default: "paste"
    field :provider_message_id, :string
    field :provider_event_id, :string

    field :classification, Ecto.Enum, values: @classifications
    field :classification_confidence, :float
    field :ai_summary, :string
    field :ai_data, :map, default: %{}
    field :correspondent_kind, Ecto.Enum, values: @correspondent_kinds

    field :status, Ecto.Enum, values: @statuses, default: :received
    field :error_message, :string

    field :delivery_status, :string
    field :delivery_events, {:array, :map}, default: []

    field :occurred_at, :utc_datetime
    field :processed_at, :utc_datetime

    belongs_to :incident, KomunBackend.Incidents.Incident
    belongs_to :pasted_by, KomunBackend.Accounts.User, foreign_key: :pasted_by_id

    timestamps(type: :utc_datetime)
  end

  def directions, do: @directions
  def sources, do: @sources
  def correspondent_kinds, do: @correspondent_kinds

  def changeset(email, attrs) do
    email
    |> cast(attrs, [
      :direction, :source, :subject,
      :from_email, :from_name, :to_email, :cc_emails, :reply_to,
      :text_body, :html_body, :raw_text, :headers,
      :provider, :provider_message_id, :provider_event_id,
      :classification, :classification_confidence, :ai_summary, :ai_data,
      :correspondent_kind,
      :status, :error_message,
      :delivery_status, :delivery_events,
      :occurred_at, :processed_at,
      :incident_id, :pasted_by_id
    ])
    |> validate_required([:direction, :source, :provider, :incident_id])
  end

  @doc """
  Append a delivery lifecycle event (Resend `email.delivered`,
  `email.opened`, `email.bounced`, …). The `delivery_status` always
  reflects the most recent type so the UI can render a single badge.
  """
  def append_delivery_event_changeset(email, event_type, payload \\ %{}) do
    new_event = %{
      "type" => to_string(event_type),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "payload" => payload
    }

    email
    |> cast(
      %{
        delivery_status: to_string(event_type),
        delivery_events: (email.delivery_events || []) ++ [new_event]
      },
      [:delivery_status, :delivery_events]
    )
  end

  @doc "Date à utiliser pour ordonner cet email dans la timeline."
  def timeline_at(%__MODULE__{occurred_at: at}) when not is_nil(at), do: at
  def timeline_at(%__MODULE__{inserted_at: at}), do: at
end
