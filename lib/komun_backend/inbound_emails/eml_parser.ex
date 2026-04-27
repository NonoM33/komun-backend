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

  Pour récupérer les pièces jointes binaires (image, PDF…) — qui ne
  doivent PAS finir dans le body texte mais bien dans `incident_files`
  — voir `extract_attachments/1`. Cette fonction parcourt l'arbre
  MIME, décode base64 / quoted-printable, et renvoie une liste
  `[%{filename, content_type, bytes}, …]` prête à être stockée via
  `KomunBackend.Incidents.LocalStorage.save_bytes/3`.

  Implémentation 100 % maison (pas de `:gen_smtp` / iconv) — on
  cible les emails Gmail / Outlook bien formés que reçoit aujourd'hui
  le syndic.
  """

  require Logger

  @placeholder_attachment_text "[Pièce jointe encodée — non incluse dans le commentaire pour rester lisible]"

  @doc "Texte injecté dans le body quand on n'arrive pas à isoler la PJ — exposé pour que le pipeline d'ingestion puisse le strip une fois la PJ correctement extraite."
  def placeholder_attachment_text, do: @placeholder_attachment_text

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

      true ->
        nil
    end
  end

  defp decode_transfer(body, nil), do: body

  defp decode_transfer(body, encoding) do
    case String.downcase(encoding) do
      "quoted-printable" -> decode_quoted_printable(body)
      "base64" -> @placeholder_attachment_text
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

  # ── Attachments extraction ────────────────────────────────────────────
  #
  # Le body texte est géré par `parse/1` au-dessus (placeholder, strip
  # HTML, troncature). Ici on s'occupe **uniquement** des pièces jointes
  # binaires : on parcourt l'arbre MIME, on collecte les parts qui ont
  # un `filename` (Content-Disposition ou Content-Type `name=`), et on
  # décode leurs bytes (base64, quoted-printable). Les parties text/plain
  # / text/html inline sans filename sont ignorées.

  @doc """
  Parcourt l'arbre MIME de l'email et renvoie les pièces jointes
  binaires déjà décodées sous la forme
  `[%{filename: String.t(), content_type: String.t(), bytes: binary()}, ...]`.

  Si l'email n'est pas multipart, ou si le parsing échoue, renvoie `[]`
  — l'idée est que cette fonction ne fasse jamais planter le pipeline
  d'ingestion : pas de PJ extraite, c'est tout, et le placeholder dans
  le body reste visible pour signaler le manque.
  """
  @spec extract_attachments(String.t()) :: [
          %{filename: String.t(), content_type: String.t(), bytes: binary()}
        ]
  def extract_attachments(raw) when is_binary(raw) do
    raw
    |> walk_part()
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  rescue
    e ->
      Logger.warning("[eml_parser] extract_attachments failed: #{inspect(e)}")
      []
  end

  # Walk a single MIME part. `raw` est soit l'email entier (au premier
  # appel), soit une sous-part (lors de la récursion). On split
  # headers/body, on regarde le Content-Type, et on bifurque :
  #   * multipart/* → on découpe par boundary et on recurse
  #   * autre       → on tente de l'extraire comme attachment
  defp walk_part(raw) do
    {headers_block, body} =
      case String.split(raw, ~r/\r?\n\r?\n/, parts: 2) do
        [h, b] -> {h, b}
        [h] -> {h, ""}
      end

    headers = parse_headers(headers_block)
    {ctype, ctype_params} = parse_content_type(headers["content-type"])

    if String.starts_with?(ctype || "", "multipart/") do
      walk_multipart(body, ctype_params)
    else
      [maybe_attachment(headers, body, ctype)]
    end
  end

  defp walk_multipart(body, %{"boundary" => boundary}) when is_binary(boundary) do
    body
    |> split_by_boundary(boundary)
    |> Enum.flat_map(&walk_part/1)
  end

  defp walk_multipart(_body, _params), do: []

  # RFC 2046 §5.1.1 : `--BOUNDARY` ouvre une part, `--BOUNDARY--` ferme
  # le multipart. Tout ce qui précède la première occurrence est un
  # préambule à ignorer. On normalise sur LF avant le split puis on
  # rejoint en CRLF pour rester cohérent avec la grammaire RFC822.
  defp split_by_boundary(body, boundary) do
    delim = "--" <> boundary
    end_delim = delim <> "--"

    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> chunk_by_delim(delim, end_delim)
    |> Enum.map(&Enum.join(&1, "\r\n"))
  end

  defp chunk_by_delim(lines, delim, end_delim) do
    {chunks, current, started?} =
      Enum.reduce(lines, {[], [], false}, fn line, {acc, cur, started?} ->
        cond do
          line == end_delim ->
            if started? and cur != [],
              do: {[Enum.reverse(cur) | acc], [], false},
              else: {acc, [], false}

          line == delim ->
            cond do
              started? and cur != [] -> {[Enum.reverse(cur) | acc], [], true}
              true -> {acc, [], true}
            end

          started? ->
            {acc, [line | cur], true}

          true ->
            {acc, cur, started?}
        end
      end)

    chunks =
      if started? and current != [],
        do: [Enum.reverse(current) | chunks],
        else: chunks

    Enum.reverse(chunks)
  end

  defp maybe_attachment(headers, body, ctype) do
    {disposition, disp_params} = parse_content_disposition(headers["content-disposition"])
    {_, ctype_params} = parse_content_type(headers["content-type"])

    encoding =
      headers["content-transfer-encoding"]
      |> to_string()
      |> String.downcase()
      |> String.trim()

    filename =
      pick_filename(disp_params) ||
        pick_filename(ctype_params)

    cond do
      is_nil(filename) ->
        nil

      disposition not in ["", "attachment", "inline"] ->
        nil

      true ->
        bytes = decode_attachment_body(body, encoding)

        if byte_size(bytes) == 0 do
          nil
        else
          %{
            filename: decode_encoded_words(filename) || filename,
            content_type: ctype || "application/octet-stream",
            bytes: bytes
          }
        end
    end
  end

  defp pick_filename(%{"filename" => f}) when is_binary(f) and f != "", do: f
  defp pick_filename(%{"name" => f}) when is_binary(f) and f != "", do: f
  defp pick_filename(_), do: nil

  defp parse_content_type(nil), do: {nil, %{}}

  defp parse_content_type(raw) do
    [type | params] = String.split(raw, ";")
    {String.downcase(String.trim(type)), parse_params(params)}
  end

  defp parse_content_disposition(nil), do: {"", %{}}

  defp parse_content_disposition(raw) do
    [disp | params] = String.split(raw, ";")
    {String.downcase(String.trim(disp)), parse_params(params)}
  end

  # `name="..."`, `filename=...`, `filename*=UTF-8''Naïve.pdf` (RFC 2231).
  # On reste pragmatique : on ne gère pas la continuation `filename*0=
  # …; filename*1=…` mais on couvre le cas `filename*=UTF-8''xxx` qui
  # est ce qu'envoie Gmail / Outlook 99 % du temps.
  defp parse_params(parts) do
    Enum.reduce(parts, %{}, fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] ->
          key = k |> String.trim() |> String.downcase()
          value = v |> String.trim() |> unquote_string()

          if String.ends_with?(key, "*") do
            base = String.trim_trailing(key, "*")
            Map.put(acc, base, decode_rfc2231(value))
          else
            Map.put_new(acc, key, value)
          end

        _ ->
          acc
      end
    end)
  end

  defp unquote_string("\"" <> rest) do
    case String.split(rest, "\"", parts: 2) do
      [inner, _] -> inner
      [v] -> v
    end
  end

  defp unquote_string(s), do: s

  defp decode_rfc2231(value) do
    case String.split(value, "'", parts: 3) do
      [_charset, _lang, encoded] -> percent_decode(encoded)
      _ -> percent_decode(value)
    end
  end

  defp percent_decode(s) do
    Regex.replace(~r/%([0-9A-Fa-f]{2})/, s, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  defp decode_attachment_body(body, "base64") do
    body
    |> String.replace(~r/\s+/, "")
    |> Base.decode64(ignore: :whitespace)
    |> case do
      {:ok, bin} -> bin
      :error -> ""
    end
  end

  defp decode_attachment_body(body, "quoted-printable") do
    body
    |> decode_quoted_printable()
    # `decode_quoted_printable/1` peut renvoyer la string brute en cas
    # de rescue — on s'assure que le résultat est bien un binaire.
    |> case do
      b when is_binary(b) -> b
      _ -> ""
    end
  end

  defp decode_attachment_body(body, _), do: body
end
