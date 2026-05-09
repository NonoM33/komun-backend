defmodule KomunBackend.InboundEmails.EmlParserTest do
  @moduledoc """
  Régression du 2026-04-27 : un email Gmail au format `multipart/related`
  englobant un `multipart/alternative` (text/plain + text/html + images
  inline) faisait fuiter l'envelope MIME brute (boundaries, Content-Type)
  dans la timeline des incidents au lieu d'extraire le `text/plain`.

  Ce test bloque la régression en construisant un mail de la même forme
  et en vérifiant que le parser :
    1. Récupère le `text/plain` (et pas l'envelope)
    2. Décode le quoted-printable
    3. N'inclut plus jamais les boundaries ni les en-têtes MIME
  """

  use ExUnit.Case, async: true

  alias KomunBackend.InboundEmails.EmlParser

  test "extrait le text/plain à travers un multipart/related → multipart/alternative" do
    eml =
      "From: Alice <alice@example.com>\r\n" <>
        "To: Bob <bob@example.com>\r\n" <>
        "Subject: Devis m=?utf-8?Q?=C3=A9?=nage\r\n" <>
        "Date: Sun, 26 Apr 2026 20:00:48 +0200\r\n" <>
        "Content-Type: multipart/related; boundary=\"OUTER\"\r\n" <>
        "\r\n" <>
        "--OUTER\r\n" <>
        "Content-Type: multipart/alternative; boundary=\"INNER\"\r\n" <>
        "\r\n" <>
        "--INNER\r\n" <>
        "Content-Type: text/plain; charset=\"UTF-8\"\r\n" <>
        "Content-Transfer-Encoding: quoted-printable\r\n" <>
        "\r\n" <>
        "Bonsoir,\r\n" <>
        "Je vous remercie de bien vouloir r=C3=A9pondre =C3=A0 ces points.\r\n" <>
        "Bien cordialement.\r\n" <>
        "--INNER\r\n" <>
        "Content-Type: text/html; charset=\"UTF-8\"\r\n" <>
        "Content-Transfer-Encoding: quoted-printable\r\n" <>
        "\r\n" <>
        "<div>Bonsoir,<br>Je vous remercie...</div>\r\n" <>
        "--INNER--\r\n" <>
        "--OUTER\r\n" <>
        "Content-Type: image/png; name=\"image001.png\"\r\n" <>
        "Content-Transfer-Encoding: base64\r\n" <>
        "\r\n" <>
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=\r\n" <>
        "--OUTER--\r\n"

    result = EmlParser.parse(eml)

    # 1. Le sujet est bien décodé (encoded-word + accent restauré)
    assert result.subject =~ "Devis ménage"

    # 2. Le body contient le texte propre, accents restaurés depuis le quoted-printable
    assert result.body =~ "Bonsoir,"
    assert result.body =~ "répondre"
    assert result.body =~ "à ces points"

    # 3. L'envelope MIME ne fuit pas dans le body — c'était le bug.
    refute result.body =~ "Content-Type:"
    refute result.body =~ "boundary="
    refute result.body =~ "--OUTER"
    refute result.body =~ "--INNER"

    # 4. Le HTML alternatif ne s'invite pas non plus dans le body texte.
    refute result.body =~ "<div>"

    # 5. La PJ image base64 n'est pas dans le body.
    refute result.body =~ "iVBORw0KGgo"
  end

  test "fallback gracieux quand aucun text/plain n'existe (que du text/html)" do
    eml =
      "From: a@b.fr\r\n" <>
        "Subject: Test\r\n" <>
        "Content-Type: text/html; charset=UTF-8\r\n" <>
        "\r\n" <>
        "<p>Hello <b>world</b></p>"

    result = EmlParser.parse(eml)

    assert result.body =~ "Hello"
    assert result.body =~ "world"
    refute result.body =~ "<b>"
  end
end
