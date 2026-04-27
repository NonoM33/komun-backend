defmodule KomunBackend.InboundEmails.EmlParserTest do
  @moduledoc """
  Couvre le décodage MIME d'un `.eml` multipart contenant une photo,
  un PDF et un mime hors whitelist. Verifie que :

    * 2 attachments « légitimes » (PNG + PDF) sortent décodés en bytes
      réels (avec leur signature de header binaire).
    * Le mime hors whitelist (`application/zip`) est extrait par le
      parser **mais** sera skippé en aval par `InboundEmails` — ce test
      vérifie juste que le parser ne plante pas dessus.
    * Un filename RFC 2231 (`filename*=UTF-8''…`) est correctement décodé.
    * `parse/1` continue à renvoyer un body lisible (pas affecté par
      l'ajout de `extract_attachments/1`).
  """

  use ExUnit.Case, async: true

  alias KomunBackend.InboundEmails.EmlParser

  # Quelques bytes en base64 pour simuler des attachments réalistes.
  # PNG 1x1 transparent — signature `\x89PNG\r\n\x1a\n` au début.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
  # En-tête minimal d'un PDF — `%PDF-1.4`.
  @pdf_b64 "JVBERi0xLjQKJcOkw7zDtsOfCg=="
  # Faux ZIP — signature `PK\x03\x04`.
  @zip_b64 "UEsDBA=="

  defp build_eml(parts) do
    headers = [
      "From: \"Alice Voisinage\" <alice@example.com>",
      "To: bob@example.com",
      "Subject: =?UTF-8?B?VGVzdCDDoCBjaGV6IG1vaQ==?=",
      "Date: Mon, 27 Apr 2026 10:00:00 +0000",
      "MIME-Version: 1.0",
      "Content-Type: multipart/mixed; boundary=\"BOUND\""
    ]

    (headers ++ ["", "preamble à ignorer"] ++ parts ++ ["--BOUND--", ""])
    |> Enum.join("\r\n")
  end

  describe "extract_attachments/1" do
    test "extrait PNG + PDF + ZIP avec leurs bytes décodés depuis base64" do
      eml =
        build_eml([
          "--BOUND",
          "Content-Type: text/plain; charset=utf-8",
          "Content-Transfer-Encoding: 7bit",
          "",
          "Bonjour le voisinage",
          "--BOUND",
          "Content-Type: image/png; name=\"pixel.png\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"pixel.png\"",
          "",
          @png_b64,
          "--BOUND",
          "Content-Type: application/pdf",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename*=UTF-8''facture-na%C3%AFve.pdf",
          "",
          @pdf_b64,
          "--BOUND",
          "Content-Type: application/zip; name=\"archive.zip\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"archive.zip\"",
          "",
          @zip_b64
        ])

      attachments = EmlParser.extract_attachments(eml)
      assert length(attachments) == 3

      png = Enum.find(attachments, &(&1.filename == "pixel.png"))
      assert png
      assert png.content_type == "image/png"
      assert binary_part(png.bytes, 0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>

      pdf = Enum.find(attachments, &(&1.filename == "facture-naïve.pdf"))
      assert pdf, "RFC 2231 filename should decode `naïve` correctly"
      assert pdf.content_type == "application/pdf"
      assert binary_part(pdf.bytes, 0, 5) == "%PDF-"

      zip = Enum.find(attachments, &(&1.filename == "archive.zip"))
      assert zip
      assert zip.content_type == "application/zip"
      assert binary_part(zip.bytes, 0, 4) == <<0x50, 0x4B, 0x03, 0x04>>
    end

    test "ignore les parties text/plain et text/html sans filename" do
      eml =
        build_eml([
          "--BOUND",
          "Content-Type: multipart/alternative; boundary=\"ALT\"",
          "",
          "--ALT",
          "Content-Type: text/plain; charset=utf-8",
          "",
          "version texte",
          "--ALT",
          "Content-Type: text/html; charset=utf-8",
          "",
          "<p>version html</p>",
          "--ALT--",
          "--BOUND",
          "Content-Type: image/png; name=\"only-attachment.png\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"only-attachment.png\"",
          "",
          @png_b64
        ])

      attachments = EmlParser.extract_attachments(eml)
      assert length(attachments) == 1
      assert hd(attachments).filename == "only-attachment.png"
    end

    test "renvoie [] si l'email n'est pas multipart" do
      raw =
        [
          "From: alice@example.com",
          "Subject: Hello",
          "Content-Type: text/plain",
          "",
          "Pas de PJ ici."
        ]
        |> Enum.join("\r\n")

      assert EmlParser.extract_attachments(raw) == []
    end

    test "renvoie [] sur un .eml malformé (pas de boundary)" do
      raw =
        [
          "From: alice@example.com",
          "Content-Type: multipart/mixed",
          "",
          "garbage"
        ]
        |> Enum.join("\r\n")

      assert EmlParser.extract_attachments(raw) == []
    end
  end

  describe "parse/1 (regression — body texte préservé)" do
    test "extrait correctement le body text/plain sans être perturbé par les PJ" do
      eml =
        build_eml([
          "--BOUND",
          "Content-Type: text/plain; charset=utf-8",
          "Content-Transfer-Encoding: 7bit",
          "",
          "Bonjour le voisinage, voici une photo.",
          "--BOUND",
          "Content-Type: image/png; name=\"pixel.png\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"pixel.png\"",
          "",
          @png_b64
        ])

      email = EmlParser.parse(eml)
      assert email.from == "alice@example.com"
      assert email.from_name == "Alice Voisinage"
      assert email.body =~ "Bonjour le voisinage"
      # Le subject était encodé RFC 2047 — doit être décodé
      assert email.subject == "Test à chez moi"
    end
  end
end
