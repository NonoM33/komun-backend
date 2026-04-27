defmodule KomunBackend.Assistant.Rule do
  @moduledoc """
  Custom prompt rule attached to a building. The list of active rules is
  injected into the system prompt of the AI assistant before each call to
  the LLM, so syndic / super_admin can steer the answers without redeploying.

  Scope: one building × N rules. `enabled: false` keeps the rule for later
  re-activation without losing the wording.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_content_length 500

  schema "assistant_rules" do
    field :content, :string
    field :enabled, :boolean, default: true
    field :position, :integer, default: 0

    belongs_to :building, KomunBackend.Buildings.Building
    belongs_to :created_by_user, KomunBackend.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def max_content_length, do: @max_content_length

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :content,
      :enabled,
      :position,
      :building_id,
      :created_by_user_id
    ])
    |> update_change(:content, &trim_or_nil/1)
    |> validate_required([:content, :building_id])
    |> validate_length(:content, min: 3, max: @max_content_length)
  end

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(value) when is_binary(value), do: String.trim(value)
end
