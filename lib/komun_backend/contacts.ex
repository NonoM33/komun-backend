defmodule KomunBackend.Contacts do
  @moduledoc """
  Annuaire de contacts par résidence — voir `KomunBackend.Contacts.Contact`.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Contacts.Contact

  # Rôles habilités à éditer l'annuaire.
  @privileged_roles [:super_admin, :syndic_manager, :syndic_staff, :president_cs, :membre_cs]
  @privileged_member_roles [:president_cs, :membre_cs]

  @doc """
  Liste les contacts d'une résidence, triés par nom (insensible à la casse).
  """
  def list_residence_contacts(residence_id) do
    from(c in Contact,
      where: c.residence_id == ^residence_id,
      order_by: [asc: fragment("lower(?)", c.name)],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  def get_contact!(id) do
    Contact
    |> Repo.get!(id)
    |> Repo.preload([:created_by])
  end

  def get_contact(id) do
    case Contact |> Repo.get(id) |> Repo.preload([:created_by]) do
      nil -> nil
      c -> c
    end
  end

  def create_contact(residence_id, user_id, attrs) do
    %Contact{residence_id: residence_id, created_by_id: user_id}
    |> Contact.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, contact} -> {:ok, Repo.preload(contact, [:created_by])}
      err -> err
    end
  end

  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, contact} -> {:ok, Repo.preload(contact, [:created_by])}
      err -> err
    end
  end

  def delete_contact(%Contact{} = contact), do: Repo.delete(contact)

  @doc """
  Vrai si l'user peut écrire dans l'annuaire de la résidence (créer /
  modifier / supprimer un contact). Lecture = tout membre, donc à
  vérifier séparément côté contrôleur.
  """
  def can_write?(_residence_id, nil), do: false
  def can_write?(_residence_id, %{role: :super_admin}), do: true
  def can_write?(residence_id, %{role: role, id: user_id}) do
    cond do
      role in @privileged_roles -> true
      privileged_member_of_residence?(residence_id, user_id) -> true
      true -> false
    end
  end

  defp privileged_member_of_residence?(residence_id, user_id) do
    Repo.exists?(
      from bm in BuildingMember,
        join: b in assoc(bm, :building),
        where:
          b.residence_id == ^residence_id and bm.user_id == ^user_id and
            bm.role in ^@privileged_member_roles
    )
  end
end
