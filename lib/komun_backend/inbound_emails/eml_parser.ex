defmodule KomunBackend.InboundEmails.EmlParser do
  @moduledoc """
  Parser RFC822 minimaliste pour transformer le contenu d'un fichier
  `.eml` en map normalisée `%{from, from_name, to, cc, subject, body,
  received_at}`.

  On ne supporte volontairement pas les MIME imbriqués multipart
  complexes — le but est d'extraire `From / To / Subject / Date` des
  headers et de récupérer un body en texte brut. Si le mail est
  multipart/alternative, on garde la première partie text/plain ; à
  défaut, la première partie text/html dont on strippe les tags.

  Pour une couverture parfaite il faudra brancher une lib type
  `mua` ou `mail` Elixir, mais ce parser couvre les forwarding Gmail
  basiques que l'admin Komun va probablement uploader.
  """

  @doc """
  Parse une string `.eml` brute. Renvoie toujours une map (en cas
  d'erreur de parsing les champs vides sont nil).
  """
  @spec parse(String.t()) :: map()
  def parse(raw) when is_binary(raw) do
    {headers_block, body_block} = split_headers(raw)
    headers = parse_headers(headers_block)

    body = decode_body(body_block, headers)

    {from_email, from_name} = parse_address(headers["from"])
    {to_email, _to_name} = parse_address(headers["to"])

    %{
      from: from_email,
      from_name: from_name,
      to: to_email,
      cc: headers["cc"],
      subject: decode_subject(headers["subject"]),
      body: body,
      received_at: parse_date(headers["date"])
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp split_headers(raw) do
    case String.split(raw, ~r/\r?\n\r?\n/, parts: 2) do
      [headers, body] -> {headers, body}
      [headers] -> {headers, ""}
    end
  end

  defp parse_headers(block) do
    block
    # Folded headers: lines starting with whitespace continue the previous one
    |> String.replace(~r/\r?\n[ \t]+/, " ")
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          k = key |> String.trim() |> String.downcase()
          # First occurrence wins (already-set means earlier in the file)
          if Map.has_key?(acc, k), do: acc, else: Map.put(acc, k, String.trim(value))

        _ ->
          acc
      end
    end)
  end

  defp parse_address(nil), do: {nil, nil}

  defp parse_address(raw) when is_binary(raw) do
    case Regex.run(~r/(?:"?([^"<]+?)"?\s*)?<([^>]+)>/, raw) do
      [_, "", email] -> {String.downcase(String.trim(email)), nil}
      [_, name, email] -> {String.downcase(String.trim(email)), String.trim(name)}
      _ -> {raw |> String.trim() |> String.downcase(), nil}
    end
  end

  # `=?utf-8?Q?…?=` and `=?utf-8?B?…?=` MIME encoded-word — best-effort
  defp decode_subject(nil), do: nil
  defp decode_subject(s) when is_binary(s) do
    Regex.replace(~r/=\?[^?]+\?[QqBb]\?[^?]+\?=/, s, fn match ->
      decode_encoded_word(match)
    end)
    |> String.trim()
  end

  defp decode_encoded_word(word) do
    case Regex.run(~r/=\?([^?]+)\?([QqBb])\?([^?]+)\?=/, word) do
      [_, _charset, "B", payload] ->
        payload |> Base.decode64!(ignore: :whitespace, padding: false)
      [_, _charset, "b", payload] ->
        payload |> Base.decode64!(ignore: :whitespace, padding: false)
      [_, _charset, "Q", payload] ->
        decode_q(payload)
      [_, _charset, "q", payload] ->
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
    |> String.replace(~r/=([0-9A-Fa-f]{2})/, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  # Body extraction : if multipart/alternative or multipart/mixed, keep
  # the first text/plain part. Otherwise treat as plain text or strip
  # HTML if Content-Type says text/html.
  defp decode_body(body, headers) do
    content_type = headers["content-type"] || ""

    cond do
      String.contains?(String.downcase(content_type), "multipart") ->
        boundary = extract_boundary(content_type)
        if boundary do
          extract_first_text_part(body, boundary)
        else
          body
        end

      String.contains?(String.downcase(content_type), "text/html") ->
        body |> strip_html() |> decode_quoted_printable_if_needed(headers)

      true ->
        decode_quoted_printable_if_needed(body, headers)
    end
    |> String.trim()
  end

  defp extract_boundary(content_type) do
    case Regex.run(~r/boundary="?([^";\s]+)"?/, content_type) do
      [_, b] -> b
      _ -> nil
    end
  end

  defp extract_first_text_part(body, boundary) do
    parts = String.split(body, "--" <> boundary)

    plain =
      Enum.find_value(parts, nil, fn part ->
        cond do
          String.match?(part, ~r/Content-Type:\s*text\/plain/i) ->
            extract_part_body(part)
          true ->
            nil
        end
      end)

    cond do
      plain && plain != "" ->
        plain

      true ->
        # Fallback : first text/html stripped
        Enum.find_value(parts, "", fn part ->
          if String.match?(part, ~r/Content-Type:\s*text\/html/i) do
            part |> extract_part_body() |> strip_html()
          end
        end)
    end
  end

  defp extract_part_body(part) do
    {part_headers, part_body} =
      case String.split(part, ~r/\r?\n\r?\n/, parts: 2) do
        [h, b] -> {parse_headers(h), b}
        _ -> {%{}, ""}
      end

    decode_quoted_printable_if_needed(part_body, part_headers)
  end

  defp decode_quoted_printable_if_needed(body, headers) do
    encoding = (headers["content-transfer-encoding"] || "") |> String.downcase()

    cond do
      String.contains?(encoding, "quoted-printable") -> decode_quoted_printable(body)
      String.contains?(encoding, "base64") ->
        body |> String.replace(~r/\s/, "") |> Base.decode64!(padding: false)
      true -> body
    end
  rescue
    _ -> body
  end

  defp decode_quoted_printable(body) do
    body
    |> String.replace(~r/=\r?\n/, "")
    |> String.replace(~r/=([0-9A-Fa-f]{2})/, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  defp strip_html(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.replace(~r/\s+\n/, "\n")

  defp parse_date(nil), do: DateTime.utc_now()
  defp parse_date(date_str) when is_binary(date_str) do
    # RFC 2822 dates are "Tue, 24 Feb 2026 07:23:18 +0100" — Calendar.strftime
    # cannot parse them, but DateTime.from_iso8601 won't either. We just
    # store the original string ; the frontend formats it for display.
    date_str
  end
end
