defmodule KomunBackend.Incidents.EmailParserTest do
  use ExUnit.Case, async: true

  alias KomunBackend.Incidents.EmailParser

  describe "parse/2" do
    test "extracts headers + body from an RFC-5322 dump" do
      raw = """
      From: Jean Syndic <jean@nexity.fr>
      To: vous@example.com
      Subject: Re: Fuite parking
      Date: Mon, 27 Apr 2026 10:00:00 +0200

      Bonjour, le plombier passe demain à 9h.
      Cordialement.
      """

      result = EmailParser.parse(raw)

      assert result.from_email == "jean@nexity.fr"
      assert result.from_name == "Jean Syndic"
      assert result.to_email == "vous@example.com"
      assert result.subject =~ "Fuite parking"
      assert result.text_body =~ "plombier passe demain"
      assert %DateTime{} = result.date
    end

    test "uses fallbacks when no headers are present" do
      raw = "Juste le corps de l'email collé sans entête."

      result = EmailParser.parse(raw, %{from_email: "voisin@example.com", subject: "Bruit nuit"})

      assert result.from_email == "voisin@example.com"
      assert result.subject == "Bruit nuit"
      assert result.text_body =~ "Juste le corps"
    end

    test "extracts the address when wrapped in <…>" do
      raw = """
      From: "Marie Dupont" <marie@example.com>
      Subject: Test

      Coucou
      """

      result = EmailParser.parse(raw)
      assert result.from_email == "marie@example.com"
      assert result.from_name == "Marie Dupont"
    end

    test "does not raise on garbled input" do
      assert %{} = EmailParser.parse("garbage \x01\x02\x03 stuff")
    end

    test "lowercases extracted addresses" do
      raw = "From: Foo <FOO@EXAMPLE.COM>\nSubject: x\n\nbody"
      result = EmailParser.parse(raw)
      assert result.from_email == "foo@example.com"
    end
  end
end
