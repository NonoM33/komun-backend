defmodule KomunBackend.LocalFeeds.ParserTest do
  use ExUnit.Case, async: true

  alias KomunBackend.LocalFeeds.Parser

  describe "parse/1 — RSS 2.0" do
    test "extracts items from a well-formed feed" do
      xml = """
      <?xml version="1.0" encoding="UTF-8" ?>
      <rss version="2.0">
        <channel>
          <title>Mairie de Wissous</title>
          <item>
            <title>Travaux rue de la Mairie</title>
            <link>https://wissous.fr/news/1</link>
            <guid>guid-1</guid>
            <description>&lt;p&gt;Routes coupées du lundi au vendredi.&lt;/p&gt;</description>
            <pubDate>Tue, 21 Apr 2026 10:00:00 GMT</pubDate>
            <enclosure url="https://wissous.fr/img/1.jpg" type="image/jpeg"/>
          </item>
        </channel>
      </rss>
      """

      assert {:ok, [item]} = Parser.parse(xml)
      assert item.guid == "guid-1"
      assert item.title == "Travaux rue de la Mairie"
      assert item.url == "https://wissous.fr/news/1"
      assert item.summary == "Routes coupées du lundi au vendredi."
      assert item.image_url == "https://wissous.fr/img/1.jpg"

      expected_dt = DateTime.from_naive!(~N[2026-04-21 10:00:00], "Etc/UTC")
      assert DateTime.compare(item.published_at, expected_dt) == :eq
    end

    test "uses a sha256-based fallback guid when none is supplied" do
      xml = """
      <rss version="2.0"><channel>
        <item>
          <title>Sans guid</title>
          <link>https://wissous.fr/x</link>
        </item>
      </channel></rss>
      """

      assert {:ok, [item]} = Parser.parse(xml)
      # 64-char lowercase hex sha256.
      assert String.match?(item.guid, ~r/^[a-f0-9]{64}$/)
    end

    test "extracts the first <img> from the description as image_url when no enclosure" do
      xml = """
      <rss version="2.0"><channel>
        <item>
          <title>T</title>
          <link>https://w/x</link>
          <description>&lt;p&gt;hello &lt;img src="https://w/p.png"&gt;&lt;/p&gt;</description>
        </item>
      </channel></rss>
      """

      assert {:ok, [item]} = Parser.parse(xml)
      assert item.image_url == "https://w/p.png"
    end

    test "drops items that have neither title nor link" do
      xml = """
      <rss version="2.0"><channel>
        <item><title>OK</title><link>https://w/1</link></item>
        <item><description>orphan</description></item>
      </channel></rss>
      """

      assert {:ok, [only]} = Parser.parse(xml)
      assert only.title == "OK"
    end

    test "returns an error for malformed XML" do
      assert {:error, _} = Parser.parse("<not valid xml")
    end
  end

  describe "parse/1 — Atom 1.0" do
    test "extracts entries from an Atom feed" do
      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Wissous Atom</title>
        <entry>
          <id>https://wissous.fr/atom/1</id>
          <title>Conseil municipal</title>
          <link href="https://wissous.fr/atom/1"/>
          <summary>Compte-rendu disponible.</summary>
          <published>2026-04-20T08:30:00Z</published>
        </entry>
      </feed>
      """

      assert {:ok, [item]} = Parser.parse(xml)
      assert item.guid == "https://wissous.fr/atom/1"
      assert item.title == "Conseil municipal"
      assert item.url == "https://wissous.fr/atom/1"
      assert item.summary == "Compte-rendu disponible."

      expected = DateTime.from_naive!(~N[2026-04-20 08:30:00], "Etc/UTC")
      assert DateTime.compare(item.published_at, expected) == :eq
    end
  end

  describe "parse/1 — limites" do
    test "tronque le résumé à 500 caractères" do
      long = String.duplicate("a", 800)

      xml = """
      <rss version="2.0"><channel>
        <item><title>T</title><link>https://w/1</link>
        <description>#{long}</description></item>
      </channel></rss>
      """

      assert {:ok, [item]} = Parser.parse(xml)
      assert String.length(item.summary) == 500
    end

    test "renvoie [] sur un document non-RSS / non-Atom reconnu" do
      assert {:ok, []} = Parser.parse("<?xml version=\"1.0\"?><root></root>")
    end
  end
end
