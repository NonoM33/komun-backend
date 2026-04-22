defmodule KomunBackend.Channels do
  @moduledoc """
  Building channels context — named threads (Général, Travaux, Évènements, …)
  that the syndic / conseil creates per residence. Residents browse them
  from the admin dashboard and use them as focused broadcast streams.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Channels.Channel

  # Roles allowed to create / edit / delete a channel. A plain copropriétaire
  # can read the list but not mutate it.
  @manager_roles [
    :super_admin,
    :syndic_manager,
    :syndic_staff,
    :president_cs,
    :membre_cs
  ]

  def manager_roles, do: @manager_roles

  def list_channels(building_id) do
    from(c in Channel,
      where: c.building_id == ^building_id,
      order_by: [asc: c.inserted_at]
    )
    |> Repo.all()
  end

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel(id), do: Repo.get(Channel, id)

  def create_channel(building_id, user_id, attrs) do
    # Normalize to string keys — Phoenix hands us string-keyed params for
    # body fields (name/description/…), and Ecto.Changeset.cast raises
    # Ecto.CastError if we mix string and atom keys in the same map.
    attrs = to_string_keyed(attrs)

    %Channel{}
    |> Channel.changeset(
      attrs
      |> Map.put("building_id", building_id)
      |> Map.put("created_by_id", user_id)
    )
    |> Repo.insert()
  end

  defp to_string_keyed(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  def delete_channel(%Channel{} = channel), do: Repo.delete(channel)
end
