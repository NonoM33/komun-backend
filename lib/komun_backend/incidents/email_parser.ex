defmodule KomunBackend.Incidents.EmailParser do
  @moduledoc """
  Parser tolérant pour les pastes d'emails.

  Deux scénarios :
  - le user colle un dump RFC-5322 complet (entêtes + ligne vide + corps)
    → on extrait From/To/Subject/Date + corps
  - le user colle juste le corps
    → on garde le tout comme `text_body`, et le caller fournit les
      fallbacks (`from_email`, `subject`, …) via le formulaire UI

  On ne lève jamais : un paste mal formé doit produire un record utilisable
  avec ce que le user a saisi en supplément.
  """

  @recognized_headers ~w[from to cc bcc subject date reply-to message-id]

  @type fallback :: %{
          optional(:from_email) => String.t() | nil,
          optional(:to_email) => String.t() | nil,
          optional(:subject) => String.t() | nil
        }

  @type result :: %{
          from_email: String.t() | nil,
          from_name: String.t() | nil,
          to_email: String.t() | nil,
          cc_emails: [String.t()],
          subject: String.t() | nil,
          date: DateTime.t() | nil,
          text_body: String.t(),
          headers: map(),
          reply_to: String.t() | nil
        }

  @spec parse(String.t(), fallback) :: result
  def parse(raw, fallback \\ %{}) when is_binary(raw) do
    {headers, body} = split_headers_and_body(raw)

    %{
      from_email: extract_address(headers["from"]) || normalize(fallback[:from_email]),
      from_name: extract_name(headers["from"]),
      to_email: extract_address(headers["to"]) || normalize(fallback[:to_email]),
      cc_emails: parse_cc(headers["cc"]),
      subject: present_or(headers["subject"], fallback[:subject]),
      date: parse_date(headers["date"]),
      text_body: present_or(body, raw) |> String.trim(),
      headers: headers,
      reply_to: extract_address(headers["reply-to"])
    }
  end

  defp split_headers_and_body(raw) do
    normalized = String.replace(raw, ~r/\r\n?/, "\n")
    first_line = normalized |> String.split("\n", parts: 2) |> List.first() || ""

    {headers, body} =
      if recognized_header?(first_line) do
        do_split(normalized)
      else
        {%{}, raw}
      end

    {headers, if(is_binary(body), do: body, else: "")}
  end

  defp do_split(normalized) do
    lines = String.split(normalized, "\n")

    {headers, body_lines, _last_key, _in_body} =
      Enum.reduce(lines, {%{}, [], nil, false}, fn line, {hdrs, body, last_key, in_body} ->
        cond do
          in_body ->
            {hdrs, body ++ [line], last_key, true}

          # Ligne vide après les entêtes → début du corps
          String.trim(line) == "" and map_size(hdrs) > 0 ->
            {hdrs, body, last_key, true}

          # Continuation d'entête (RFC 5322 — ligne qui commence par espace)
          last_key && String.starts_with?(line, [" ", "\t"]) ->
            {Map.update!(hdrs, last_key, &(&1 <> " " <> String.trim(line))), body, last_key, false}

          # Nouvelle entête reconnue
          true ->
            case Regex.run(~r/\A([A-Za-z-]+):\s*(.*)\z/, line) do
              [_, key, value] ->
                key_lower = String.downcase(key)

                if key_lower in @recognized_headers do
                  {Map.put(hdrs, key_lower, String.trim_trailing(value)), body, key_lower, false}
                else
                  {hdrs, body ++ [line], last_key, true}
                end

              _ ->
                {hdrs, body ++ [line], last_key, true}
            end
        end
      end)

    {headers, Enum.join(body_lines, "\n")}
  end

  defp recognized_header?(line) do
    case Regex.run(~r/\A([A-Za-z-]+):\s*\S/, line) do
      [_, key] -> String.downcase(key) in @recognized_headers
      _ -> false
    end
  end

  # ── address helpers ─────────────────────────────────────────────────────

  defp extract_address(nil), do: nil
  defp extract_address(""), do: nil
  defp extract_address(value) do
    cond do
      m = Regex.run(~r/<([^>]+)>/, value) ->
        m |> List.last() |> String.trim() |> String.downcase()

      Regex.match?(~r/[\w.+-]+@[\w.-]+\.\w+/, value) ->
        Regex.run(~r/[\w.+-]+@[\w.-]+\.\w+/, value) |> hd() |> String.downcase()

      true ->
        nil
    end
  end

  defp extract_name(nil), do: nil
  defp extract_name(value) do
    if String.contains?(value, "<") do
      value
      |> String.split("<", parts: 2)
      |> hd()
      |> String.trim()
      |> String.trim("\"")
      |> case do
        "" -> nil
        name -> name
      end
    end
  end

  defp parse_cc(nil), do: []
  defp parse_cc(value) do
    value
    |> String.split(",")
    |> Enum.map(&extract_address(String.trim(&1)))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_date(nil), do: nil
  defp parse_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        # RFC 2822 ("Mon, 27 Apr 2026 10:00:00 +0200") — Elixir n'a pas de
        # parser natif ; on tente une conversion best-effort en remplaçant
        # le format usuel par ISO-8601.
        case Regex.run(~r/(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*([+-]\d{4})?/, value) do
          [_, d, mon, y, h, m, s, offset] ->
            month_num = month_num(mon)

            if month_num do
              iso = "#{y}-#{pad(month_num)}-#{pad(d)}T#{h}:#{m}:#{s}#{format_offset(offset)}"

              case DateTime.from_iso8601(iso) do
                {:ok, dt, _} -> dt
                _ -> nil
              end
            end

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp pad(n) when is_integer(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp pad(s) when is_binary(s), do: String.pad_leading(s, 2, "0")

  defp format_offset(""), do: "Z"
  defp format_offset(<<sign, h1, h2, m1, m2>>), do: <<sign, h1, h2, ":", m1, m2>>

  @months %{
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
    "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
  }
  defp month_num(short), do: Map.get(@months, short)

  defp normalize(nil), do: nil
  defp normalize(""), do: nil
  defp normalize(s) when is_binary(s), do: s |> String.trim() |> String.downcase()

  defp present_or(nil, fallback), do: fallback
  defp present_or("", fallback), do: fallback
  defp present_or(v, _), do: v
end
