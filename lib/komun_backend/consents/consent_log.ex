defmodule KomunBackend.Consents.ConsentLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources ~w(banner_all banner_essential banner_custom settings withdraw)

  schema "consent_logs" do
    field :visitor_id, :string
    field :essential, :boolean, default: true
    field :analytics, :boolean, default: false
    field :session_replay, :boolean, default: false
    field :marketing, :boolean, default: false
    field :source, :string
    field :policy_version, :string
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :user, KomunBackend.Accounts.User
    belongs_to :organization, KomunBackend.Organizations.Organization

    timestamps(type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :user_id, :organization_id, :visitor_id,
      :essential, :analytics, :session_replay, :marketing,
      :source, :policy_version, :ip_address, :user_agent
    ])
    |> validate_required([:source, :policy_version])
    |> validate_inclusion(:source, @sources)
    |> validate_user_or_visitor()
  end

  defp validate_user_or_visitor(changeset) do
    user_id = get_field(changeset, :user_id)
    visitor_id = get_field(changeset, :visitor_id)

    if is_nil(user_id) and (is_nil(visitor_id) or visitor_id == "") do
      add_error(changeset, :visitor_id, "user_id or visitor_id required")
    else
      changeset
    end
  end
end
