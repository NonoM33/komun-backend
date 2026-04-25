defmodule KomunBackend.LocalFeeds.Parser do
  @moduledoc """
  Parseur unifié RSS 2.0 / Atom 1.0. À partir d'un body XML brut,
  retourne une liste d'attrs prêts pour `RssFeedItem.changeset/2`.

  Conçu pour être tolérant : feed mal formé → `{:error, reason}` plutôt
  que crash. Items individuels mal formés → ignorés silencieusement
  (mais comptés dans le retour).
  """

  import SweetXml

  @max_summary_length 500

  @type attrs :: %{
          guid: String.t(),
          title: String.t(),
          url: String.t(),
          summary: String.t() | nil,
          image_url: String.t() | nil,
          published_at: DateTime.t() | nil
        }

  @doc """
  Parse un body XML et renvoie `{:ok, items}` ou `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, [attrs()]} | {:error, atom() | String.t()}
  def parse(body) when is_binary(body) do
    try do
      doc = SweetXml.parse(body, namespace_conformant: true, quiet: true)
      type = detect_type(doc)
      items = extract_items(doc, type)
      {:ok, items}
    rescue
      e -> {:error, "parse_error: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "parse_exit: #{inspect(reason)}"}
    end
  end

  # ── Detection ───────────────────────────────────────────────────────────

  defp detect_type(doc) do
    cond do
      xpath(doc, ~x"//rss") -> :rss
      xpath(doc, ~x"//channel/item") -> :rss
      xpath(doc, ~x"//*[local-name()='feed']") -> :atom
      true -> :unknown
    end
  end

  # ── Extraction ──────────────────────────────────────────────────────────

  defp extract_items(doc, :rss) do
    doc
    |> xpath(~x"//channel/item"l)
    |> Enum.map(&rss_item_to_attrs/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_items(doc, :atom) do
    doc
    |> xpath(~x"//*[local-name()='feed']/*[local-name()='entry']"l)
    |> Enum.map(&atom_entry_to_attrs/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_items(_doc, :unknown), do: []

  # ── RSS 2.0 ─────────────────────────────────────────────────────────────

  defp rss_item_to_attrs(node) do
    title = node |> xpath(~x"./title/text()"s) |> normalize_text()
    link = node |> xpath(~x"./link/text()"s) |> normalize_text()

    if title == "" or link == "" do
      nil
    else
      guid_raw = node |> xpath(~x"./guid/text()"s) |> normalize_text()
      guid = if guid_raw != "", do: guid_raw, else: fallback_guid(link, title)

      description = node |> xpath(~x"./description/text()"s) |> normalize_text()

      image =
        node
        |> xpath(~x"./enclosure/@url"s)
        |> normalize_text()
        |> first_present(extract_first_image_in_html(description))

      pub_date =
        node
        |> xpath(~x"./pubDate/text()"s)
        |> normalize_text()
        |> parse_date()

      %{
        guid: String.slice(guid, 0, 512),
        title: String.slice(title, 0, 512),
        url: String.slice(link, 0, 2048),
        summary: clean_summary(description),
        image_url: nilify_blank(image),
        published_at: pub_date
      }
    end
  end

  # ── Atom 1.0 ────────────────────────────────────────────────────────────

  defp atom_entry_to_attrs(node) do
    title = node |> xpath(~x"./*[local-name()='title']/text()"s) |> normalize_text()

    link =
      node
      |> xpath(~x"./*[local-name()='link'][not(@rel) or @rel='alternate']/@href"s)
      |> normalize_text()

    if title == "" or link == "" do
      nil
    else
      id_raw = node |> xpath(~x"./*[local-name()='id']/text()"s) |> normalize_text()
      guid = if id_raw != "", do: id_raw, else: fallback_guid(link, title)

      summary =
        node
        |> xpath(~x"./*[local-name()='summary']/text()"s)
        |> normalize_text()
        |> first_present(node |> xpath(~x"./*[local-name()='content']/text()"s) |> normalize_text())

      published =
        node
        |> xpath(~x"./*[local-name()='published']/text()"s)
        |> normalize_text()
        |> first_present(node |> xpath(~x"./*[local-name()='updated']/text()"s) |> normalize_text())
        |> parse_date()

      %{
        guid: String.slice(guid, 0, 512),
        title: String.slice(title, 0, 512),
        url: String.slice(link, 0, 2048),
        summary: clean_summary(summary),
        image_url: nilify_blank(extract_first_image_in_html(summary)),
        published_at: published
      }
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_list(value) do
    value |> List.to_string() |> normalize_text()
  end

  defp normalize_text(value) when is_binary(value) do
    String.trim(value)
  end

  defp first_present("", fallback), do: fallback
  defp first_present(nil, fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp nilify_blank(""), do: nil
  defp nilify_blank(nil), do: nil
  defp nilify_blank(value), do: value

  defp fallback_guid(link, title) do
    :crypto.hash(:sha256, link <> "|" <> title)
    |> Base.encode16(case: :lower)
  end

  defp clean_summary(nil), do: nil
  defp clean_summary(""), do: nil

  defp clean_summary(text) when is_binary(text) do
    text
    |> strip_html()
    |> String.trim()
    |> String.slice(0, @max_summary_length)
    |> nilify_blank()
  end

  # Strip HTML très basique (pas de Floki dans les deps). Suffisant pour
  # les `<description>` et `<summary>` des flux les plus courants.
  defp strip_html(text) do
    text
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
  end

  defp extract_first_image_in_html(nil), do: nil

  defp extract_first_image_in_html(html) when is_binary(html) do
    case Regex.run(~r/<img[^>]+src=["']([^"']+)["']/i, html) do
      [_, src] -> src
      _ -> nil
    end
  end

  # Parse RFC 822 (RSS pubDate) puis ISO 8601 (Atom). Retourne nil sur échec.
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(value) when is_binary(value) do
    parse_rfc1123(value) || parse_iso8601(value)
  end

  defp parse_rfc1123(value) do
    # `apply/3` shields xref from static-check noise about the OTP `:inets`
    # module; we declare `:inets` in `extra_applications` so the module is
    # available at runtime.
    try do
      case apply(:httpd_util, :convert_request_date, [String.to_charlist(value)]) do
        {{year, month, day}, {hour, min, sec}} ->
          {:ok, dt} =
            DateTime.new(
              Date.new!(year, month, day),
              Time.new!(hour, min, sec),
              "Etc/UTC"
            )

          DateTime.truncate(dt, :second)

        _ ->
          nil
      end
    rescue
      _ -> nil
    end
  end

  defp parse_iso8601(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end
end
