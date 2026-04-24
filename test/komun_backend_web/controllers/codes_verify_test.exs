defmodule KomunBackendWeb.CodesVerifyTest do
  @moduledoc """
  Tests du endpoint unifié `GET /api/v1/codes/verify?code=XXX`.

  Ce endpoint est public (pas d'auth) et résout un code en :
  - résidence → renvoie la liste de ses bâtiments (l'user choisit dans la
    page d'inscription)
  - bâtiment → renvoie le bâtiment + sa résidence parent (join direct)
  - 404 si inconnu.
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Repo
  alias KomunBackend.Residences
  alias KomunBackend.Residences.Residence
  alias KomunBackend.Buildings.Building

  defp insert_residence!(code) do
    {:ok, r} =
      %Residence{}
      |> Residence.changeset(%{
        name: "Résidence Unissons",
        address: "17 route d'Antony",
        city: "Wissous",
        postal_code: "91320",
        join_code: code
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence, code, name) do
    %Building{}
    |> Building.admin_changeset(%{
      name: name,
      address: "17 route d'Antony",
      city: "Wissous",
      postal_code: "91320",
      residence_id: residence.id,
      join_code: code
    })
    |> Repo.insert!()
  end

  test "résout un code résidence et retourne ses bâtiments", %{conn: conn} do
    residence = insert_residence!("UNISSONS")
    _b1 = insert_building!(residence, "BATIMNT1", "Bâtiment A")
    _b2 = insert_building!(residence, "BATIMNT2", "Bâtiment B")

    body =
      conn
      |> get(~p"/api/v1/codes/verify?code=UNISSONS")
      |> json_response(200)

    assert body["valid"] == true
    assert body["type"] == "residence"
    assert body["residence"]["name"] == "Résidence Unissons"
    assert length(body["buildings"]) == 2

    names = body["buildings"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["Bâtiment A", "Bâtiment B"]
  end

  test "résout un code bâtiment et retourne sa résidence parent", %{conn: conn} do
    residence = insert_residence!("UNISSON2")
    _b = insert_building!(residence, "BATDIREC", "Bâtiment A")

    body =
      conn
      |> get(~p"/api/v1/codes/verify?code=BATDIREC")
      |> json_response(200)

    assert body["valid"] == true
    assert body["type"] == "building"
    assert body["building"]["name"] == "Bâtiment A"
    assert body["residence"]["name"] == "Résidence Unissons"
  end

  test "retourne 404 sur code inconnu", %{conn: conn} do
    body = conn |> get(~p"/api/v1/codes/verify?code=NEVEREXI") |> json_response(404)
    assert body["valid"] == false
  end

  test "est insensible à la casse", %{conn: conn} do
    residence = insert_residence!("MIXEDCAS")
    _b = insert_building!(residence, "DIRECT01", "Bât A")

    body =
      conn
      |> get(~p"/api/v1/codes/verify?code=mixedcas")
      |> json_response(200)

    assert body["type"] == "residence"
    assert body["residence"]["name"] == "Résidence Unissons"
  end

  test "masque le bâtiment placeholder qui porte le même nom que la résidence", %{
    conn: conn
  } do
    # Cas répro post-migration : une résidence "unissons" a hérité d'un
    # bâtiment homonyme auto-créé, puis le user a déplacé Batiment A et
    # Batiment B dedans. À l'inscription, il ne faut pas proposer au
    # voisin de rejoindre "unissons" (placeholder) dans la liste.
    residence = insert_residence!("PLACEHLD")
    _placeholder = insert_building!(residence, "PLACED01", "Résidence Unissons")
    _a = insert_building!(residence, "PLACED02", "Bâtiment A")
    _b = insert_building!(residence, "PLACED03", "Bâtiment B")

    body =
      conn
      |> get(~p"/api/v1/codes/verify?code=PLACEHLD")
      |> json_response(200)

    names = body["buildings"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["Bâtiment A", "Bâtiment B"]
  end

  test "ne filtre PAS quand la résidence n'a qu'un bâtiment (même homonyme)", %{
    conn: conn
  } do
    # Cas limite : résidence mono-bâtiment où le building porte vraiment
    # le même nom que la copro. Il faut le garder visible, sinon la liste
    # se retrouve vide et l'user ne peut rien choisir.
    residence = insert_residence!("MONOBAT1")
    _only = insert_building!(residence, "MONOBAT2", "Résidence Unissons")

    body =
      conn
      |> get(~p"/api/v1/codes/verify?code=MONOBAT1")
      |> json_response(200)

    assert length(body["buildings"]) == 1
  end

  test "priorise le match résidence si deux codes identiques existaient (impossible en DB)", %{
    conn: conn
  } do
    # Ce test documente la priorité : `verify_code` essaie d'abord la table
    # residences, puis buildings. Les deux tables ont chacune un unique_index
    # sur join_code, mais rien n'empêche un code dans r_codes == code dans
    # b_codes. Quand ça arrive, la résidence gagne (plus "haut niveau").
    residence = insert_residence!("CLASHCOD")

    # On triche : on force le même code sur un building via Repo.update!
    # (le changeset ne l'empêche pas tant que unique_index n'est pas violé).
    {:ok, other_residence} =
      Residences.create_residence(%{name: "Autre", join_code: "OTHER001"})

    building =
      insert_building!(other_residence, "DIFFRNT1", "Bât X")
      |> Ecto.Changeset.change(join_code: "CLASHCOD")
      |> Repo.update!()

    body =
      conn
      |> get(~p"/api/v1/codes/verify?code=CLASHCOD")
      |> json_response(200)

    assert body["type"] == "residence"
    assert body["residence"]["id"] == residence.id
    refute body["building"] == building.id
  end
end
