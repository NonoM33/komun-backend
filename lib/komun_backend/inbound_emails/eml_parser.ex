defmodule KomunBackend.InboundEmails.EmlParser do
  @moduledoc """
  Parser RFC822 minimaliste — split headers / body, regex sur les
  headers principaux, body en clair.

  On ne décode volontairement PAS le quoted-printable ni les MIME
  multipart : Groq tolère très bien le bruit (=20, =3D…) et l'admin
  uploade rarement plus de 50 emails à la fois. Si le besoin de
  propreté apparaît, brancher une lib Elixir dédiée (`mua`, `mail`).
  """

  @doc "Parse une string `.eml` brute. Renvoie une map `%{from, from_name, to, cc, subject, body, received_at}`."
  @spec parse(String.t()) :: map()
  def parse(raw) when is_binary(raw) do
    {headers_block, body} =
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
      subject: headers["subject"],
      body: String.trim(body || ""),
      received_at: headers["date"]
    }
  end

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
end
