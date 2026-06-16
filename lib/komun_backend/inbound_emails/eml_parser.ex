defmodule KomunBackend.InboundEmails.EmlParser do
  @moduledoc """
  Parser RFC822 minimaliste — extrait headers + body lisible.

  Stratégie :

  1. Split sur la première ligne vide → headers / corps
  2. Headers : regex pour `From / To / Cc / Subject / Date`,
     décodage des MIME encoded-words (`=?utf-8?Q?...?=`)
  3. Corps : si l'email est multipart, on garde la première partie
     `text/plain` ; sinon le corps brut. On décode le
     quoted-printable et on strippe les attachments base64 pour
     que le commentaire soit lisible et que la limite des 100 Ko
     côté schema ne soit pas atteinte par des PDF/images encodés
     en base64.
  """

  @doc "Parse une string `.eml` brute. Renvoie une map normalisée."
  @spec parse(String.t()) :: map()
  def parse(raw) when is_binary(raw) do
    {headers_block, body_block} =
      case String.split(raw, ~r/\r?\n\r?\n/, parts: 2) do
        [h, b] -> {h, b}
        [h] -> {h, ""}
      end

    headers = parse_headers(headers_block)
    {from_email, from_name} = parse_address(headers["from"])
    {to_email, _} = parse_address(headers["to"])

    %{
      from: from_email,
      from_name: from_name,
      to: to_email,
      cc: headers["cc"],
      subject: decode_encoded_words(headers["subject"]),
      body: extract_readable_body(body_block, headers),
      received_at: headers["date"]
    }
  end

  # ── Headers ───────────────────────────────────────────────────────────

  defp parse_headers(block) do
    block
    |> String.replace(~r/\r?\n[ \t]+/, " ")
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          k = key |> String.trim() |> String.downcase()
          if Map.has_key?(acc, k), do: acc, else: Map.put(acc, k, String.trim(value))

        _ ->
          acc
      end
    end)
  end

  defp parse_address(nil), do: {nil, nil}

  defp parse_address(raw) when is_binary(raw) do
    case Regex.run(~r/<([^>]+)>/, raw) do
      [_, email] ->
        name =
          raw
          |> String.split("<", parts: 2)
          |> List.first()
          |> to_string()
          |> String.trim()
          |> String.replace(~r/^"|"$/, "")
          |> case do
            "" -> nil
            n -> n
          end

        {String.downcase(String.trim(email)), name}

      _ ->
        {raw |> String.trim() |> String.downcase(), nil}
    end
  end

  # ── Body ──────────────────────────────────────────────────────────────

  defp extract_readable_body(body, headers) do
    content_type = headers["content-type"] || ""

    text =
      cond do
        String.contains?(String.downcase(content_type), "multipart") ->
          extract_text_part(body, content_type) || strip_html(body)

        String.contains?(String.downcase(content_type), "text/html") ->
          strip_html(body)

        true ->
          body
      end

    text
    |> decode_transfer(headers["content-transfer-encoding"])
    |> String.trim()
    |> truncate(50_000)
  end

  defp extract_text_part(body, content_type) do
    boundary = extract_boundary(content_type)

    cond do
      is_nil(boundary) ->
        nil

      true ->
        body
        |> String.split("--" <> boundary)
        |> Enum.find_value(nil, &part_text_plain/1)
    end
  end

  defp extract_boundary(content_type) do
    case Regex.run(~r/boundary="?([^";\s]+)"?/, content_type) do
      [_, b] -> b
      _ -> nil
    end
  end

  # Cherche un `text/plain` dans une part. Si la part est elle-même
  # un `multipart/*` (cas Gmail typique : multipart/related → multipart/
  # alternative → text/plain + text/html + images), on récurse via
  # `extract_text_part/2` au lieu de renvoyer nil — sans ça, le
  # commentaire timeline contenait l'envelope MIME brute (boundaries,
  # `Content-Type`, etc.) au lieu du texte lisible.
  defp part_text_plain(part) do
    {part_headers, part_body} =
      case String.split(part, ~r/\r?\n\r?\n/, parts: 2) do
        [h, b] -> {parse_headers(h), b}
        _ -> {%{}, ""}
      end

    ct = String.downcase(part_headers["content-type"] || "")

    cond do
      String.contains?(ct, "text/plain") ->
        decode_transfer(part_body, part_headers["content-transfer-encoding"])

      String.contains?(ct, "multipart") ->
        extract_text_part(part_body, part_headers["content-type"])

      true ->
        nil
    end
  end

  defp decode_transfer(body, nil), do: body

  defp decode_transfer(body, encoding) do
    case String.downcase(encoding) do
      "quoted-printable" -> decode_quoted_printable(body)
      "base64" -> "[Pièce jointe encodée — non incluse dans le commentaire pour rester lisible]"
      _ -> body
    end
  end

  defp decode_quoted_printable(body) do
    body
    |> String.replace(~r/=\r?\n/, "")
    |> (fn str ->
          Regex.replace(~r/=([0-9A-Fa-f]{2})/, str, fn _full, hex ->
            <<String.to_integer(hex, 16)>>
          end)
        end).()
  rescue
    _ -> body
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max do
      String.slice(s, 0, max) <> "\n\n[…tronqué pour respecter les limites de la timeline]"
    else
      s
    end
  end

  # ── MIME encoded-words : =?utf-8?Q?...?= et =?utf-8?B?...?= ──────────

  defp decode_encoded_words(nil), do: nil

  defp decode_encoded_words(s) when is_binary(s) do
    Regex.replace(~r/=\?[^?]+\?[QqBb]\?[^?]+\?=/, s, fn match ->
      decode_encoded_word(match)
    end)
    |> String.trim()
  end

  defp decode_encoded_word(word) do
    case Regex.run(~r/=\?([^?]+)\?([QqBb])\?([^?]+)\?=/, word) do
      [_, _charset, b, payload] when b in ["B", "b"] ->
        Base.decode64!(payload, ignore: :whitespace, padding: false)

      [_, _charset, q, payload] when q in ["Q", "q"] ->
        decode_q(payload)

      _ ->
        word
    end
  rescue
    _ -> word
  end

  defp decode_q(s) do
    s
    |> String.replace("_", " ")
    |> (fn str ->
          Regex.replace(~r/=([0-9A-Fa-f]{2})/, str, fn _full, hex ->
            <<String.to_integer(hex, 16)>>
          end)
        end).()
  end
end
