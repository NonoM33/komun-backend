defmodule KomunBackendWeb.ContactController do
  @moduledoc """
  Annuaire de contacts d'une résidence — voir `KomunBackend.Contacts`.

  Routes :

    * `GET    /api/v1/residences/:residence_id/contacts`         → index
    * `POST   /api/v1/residences/:residence_id/contacts`         → create
    * `GET    /api/v1/residences/:residence_id/contacts/:id`     → show
    * `PATCH  /api/v1/residences/:residence_id/contacts/:id`     → update
    * `DELETE /api/v1/residences/:residence_id/contacts/:id`     → delete

  ## Authorization

    * Lecture (index / show) : tout user membre d'au moins un bâtiment
      de la résidence (`:super_admin` aussi).
    * Écriture (create / update / delete) : conseil syndical, syndic,
      `:super_admin` (cf. `Contacts.can_write?/2`).
  """

  use KomunBackendWeb, :controller

  import Ecto.Query

  alias KomunBackend.{Contacts, Repo, Residences}
  alias KomunBackend.Auth.Guardian
  alias KomunBackend.Buildings.BuildingMember
  alias KomunBackend.Contacts.Contact

  def index(conn, %{"residence_id" => residence_id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, residence_id, user) do
      contacts = Contacts.list_residence_contacts(residence_id)
      json(conn, %{data: Enum.map(contacts, &contact_json/1)})
    else
      %Plug.Conn{} = halted -> halted
    end
  end

  def show(conn, %{"residence_id" => residence_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_member(conn, residence_id, user),
         %Contact{} = contact <- fetch_scoped(residence_id, id) do
      json(conn, %{data: contact_json(contact)})
    else
      nil -> not_found(conn)
      %Plug.Conn{} = halted -> halted
    end
  end

  def create(conn, %{"residence_id" => residence_id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "contact", %{})

    with :ok <- authorize_writer(conn, residence_id, user),
         {:ok, contact} <- Contacts.create_contact(residence_id, user.id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: contact_json(contact)})
    else
      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  def update(conn, %{"residence_id" => residence_id, "id" => id} = params) do
    user = Guardian.Plug.current_resource(conn)
    attrs = Map.get(params, "contact", %{})

    with :ok <- authorize_writer(conn, residence_id, user),
         %Contact{} = contact <- fetch_scoped(residence_id, id),
         {:ok, contact} <- Contacts.update_contact(contact, attrs) do
      json(conn, %{data: contact_json(contact)})
    else
      nil ->
        not_found(conn)

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(cs)})

      %Plug.Conn{} = halted ->
        halted
    end
  end

  def delete(conn, %{"residence_id" => residence_id, "id" => id}) do
    user = Guardian.Plug.current_resource(conn)

    with :ok <- authorize_writer(conn, residence_id, user),
         %Contact{} = contact <- fetch_scoped(residence_id, id),
         {:ok, _} <- Contacts.delete_contact(contact) do
      send_resp(conn, :no_content, "")
    else
      nil -> not_found(conn)
      %Plug.Conn{} = halted -> halted
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  # Récupère le contact en s'assurant qu'il appartient bien à la résidence
  # de l'URL — défense en profondeur contre une manipulation d'URL
  # (`/residences/A/contacts/<id-de-B>`).
  defp fetch_scoped(residence_id, id) do
    case Repo.get_by(Contact, id: id, residence_id: residence_id) do
      nil -> nil
      c -> Repo.preload(c, [:created_by])
    end
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> json(%{error: "Contact introuvable"})
  end

  # Lecture : super_admin OU membre d'au moins un bâtiment de la résidence.
  defp authorize_member(conn, residence_id, user) do
    cond do
      is_nil(Residences.get_residence(residence_id)) ->
        conn |> put_status(:not_found) |> json(%{error: "Résidence introuvable"}) |> halt()

      is_nil(user) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Non authentifié"}) |> halt()

      user.role == :super_admin ->
        :ok

      member_of_residence?(residence_id, user.id) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Vous n'êtes membre d'aucun bâtiment de cette résidence"})
        |> halt()
    end
  end

  # Écriture : super_admin / syndic / conseil syndical (membre privilégié).
  defp authorize_writer(conn, residence_id, user) do
    cond do
      is_nil(Residences.get_residence(residence_id)) ->
        conn |> put_status(:not_found) |> json(%{error: "Résidence introuvable"}) |> halt()

      Contacts.can_write?(residence_id, user) ->
        :ok

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Réservé au syndic et au conseil syndical"})
        |> halt()
    end
  end

  defp member_of_residence?(residence_id, user_id) do
    Repo.exists?(
      from bm in BuildingMember,
        join: b in assoc(bm, :building),
        where: b.residence_id == ^residence_id and bm.user_id == ^user_id
    )
  end

  # ── Serializer ────────────────────────────────────────────────────────

  defp contact_json(%Contact{} = c) do
    %{
      id: c.id,
      residence_id: c.residence_id,
      name: c.name,
      kind: c.kind,
      title: c.title,
      email: c.email,
      phone: c.phone,
      address: c.address,
      notes: c.notes,
      created_by: maybe_user(c.created_by),
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp maybe_user(%Ecto.Association.NotLoaded{}), do: nil
  defp maybe_user(nil), do: nil

  defp maybe_user(u) do
    %{
      id: u.id,
      email: u.email,
      first_name: u.first_name,
      last_name: u.last_name
    }
  end

  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
