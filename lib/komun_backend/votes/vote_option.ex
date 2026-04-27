defmodule KomunBackend.Votes.VoteOption do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vote_options" do
    field :label, :string
    field :position, :integer, default: 0
    field :is_recommended, :boolean, default: false

    field :attachment_url, :string
    field :attachment_filename, :string
    field :attachment_mime_type, :string
    field :attachment_size_bytes, :integer

    field :external_url, :string

    belongs_to :vote, KomunBackend.Votes.Vote
    belongs_to :devis, KomunBackend.Projects.Devis

    timestamps(type: :utc_datetime)
  end

  @cast_fields [
    :label,
    :position,
    :is_recommended,
    :devis_id,
    :attachment_url,
    :attachment_filename,
    :attachment_mime_type,
    :attachment_size_bytes,
    :external_url
  ]

  def changeset(option, attrs) do
    option
    |> cast(attrs, @cast_fields)
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: 200)
    |> validate_length(:external_url, max: 2048)
    |> validate_external_url(:external_url)
  end

  # URL marchande (Amazon, Leroy Merlin, etc.) — strict HTTP/HTTPS, host
  # obligatoire. Refuse `javascript:`, `data:`, `file:` et autres schémas
  # potentiellement piégeux qu'un copropriétaire pourrait coller.
  defp validate_external_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) or value == "" ->
          []

        true ->
          case URI.parse(value) do
            %URI{scheme: scheme, host: host}
            when scheme in ["http", "https"] and is_binary(host) and host != "" ->
              []

            _ ->
              [{field, "doit être une URL HTTP(S) valide"}]
          end
      end
    end)
  end
end
