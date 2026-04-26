defmodule KomunBackend.Incidents.IncidentEmailMailer do
  @moduledoc """
  Construit + délivre via Swoosh + Resend les emails sortants liés à un
  incident.

  Le From par défaut, le Reply-To et le CC d'archivage sont injectés
  automatiquement à partir de `EmailAddressing` — l'appelant n'a qu'à
  fournir to / subject / body.
  """

  import Swoosh.Email
  alias KomunBackend.Mailer
  alias KomunBackend.Incidents.{EmailAddressing, Incident}

  @doc """
  Construit + envoie. Retourne `{:ok, %{message_id: …, raw: …}}` ou
  `{:error, raison}`.

  Resend (via Swoosh.Adapters.Resend) renvoie le message id dans
  `Map.get(metadata, "id")` après deliver — on l'expose dans le résultat.
  """
  def deliver(%Incident{} = incident, attrs) do
    archive_alias = EmailAddressing.incident_alias(incident)
    to_list = normalize_list(attrs[:to])
    cc_list = normalize_list(attrs[:cc]) ++ [archive_alias]
    bcc_list = normalize_list(attrs[:bcc])

    email =
      new()
      |> from(attrs[:from] || EmailAddressing.from_default())
      |> to(to_list)
      |> cc(Enum.uniq(cc_list))
      |> reply_to(archive_alias)
      |> subject(attrs[:subject] || "")
      |> maybe_text_body(attrs[:text])
      |> maybe_html_body(attrs[:html])
      |> maybe_bcc(bcc_list)

    case Mailer.deliver(email) do
      {:ok, metadata} ->
        {:ok,
         %{
           message_id: Map.get(metadata || %{}, "id") || Map.get(metadata || %{}, :id),
           raw: metadata,
           cc: cc_list,
           reply_to: archive_alias
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_text_body(email, nil), do: email
  defp maybe_text_body(email, ""), do: email
  defp maybe_text_body(email, t), do: text_body(email, t)

  defp maybe_html_body(email, nil), do: email
  defp maybe_html_body(email, ""), do: email
  defp maybe_html_body(email, h), do: html_body(email, h)

  defp maybe_bcc(email, []), do: email
  defp maybe_bcc(email, bcc), do: bcc(email, bcc)

  defp normalize_list(nil), do: []
  defp normalize_list(v) when is_binary(v), do: [v]
  defp normalize_list(v) when is_list(v), do: Enum.reject(v, &(&1 in [nil, ""]))
end
