defmodule KomunBackend.Incidents.EmailAddressing do
  @moduledoc """
  Convention d'adressage des emails de correspondance pour un incident.

  L'adresse `incident-{id}@inbox.komun.app` :
  - est générée pour chaque incident
  - est mise en CC + Reply-To sur les emails sortants → réponses round-trippent
  - est détectée dans le To/Cc/Bcc du webhook inbound → on bind direct

  Centralisé dans un module unique pour éviter que webhook, sender et UI
  divergent — un seul endroit définit le pattern, on règle dans Coolify
  via `KOMUN_INBOX_DOMAIN`.
  """

  @alias_regex ~r/\Aincident-(?<id>[A-Za-z0-9-]+)\b/i

  @doc "Domaine d'inbox configuré (via env, défaut `inbox.komun.app`)."
  def domain do
    System.get_env("KOMUN_INBOX_DOMAIN") || "inbox.komun.app"
  end

  @doc "From par défaut des emails sortants (via env)."
  def from_default do
    System.get_env("KOMUN_OUTBOUND_FROM") || "Komun <noreply@komun.app>"
  end

  @doc """
  Construit l'adresse d'archivage d'un incident :
  `incident-<uuid>@<domaine>`. Accepte un id direct ou une struct avec `:id`.
  """
  def incident_alias(%{id: id}), do: incident_alias(id)
  def incident_alias(id) when is_binary(id) or is_integer(id) do
    "incident-#{id}@#{domain()}"
  end

  @doc """
  Extrait l'incident UUID (binary_id) depuis une adresse email. Retourne
  `nil` si l'adresse ne suit pas le pattern. Tolère le suffixe `+tag` :
  `incident-uuid+nexity@inbox.komun.app` matche aussi.
  """
  def extract_incident_id(nil), do: nil
  def extract_incident_id(""), do: nil
  def extract_incident_id(addr) when is_binary(addr) do
    [local | _] = String.split(addr, "@", parts: 2)

    case Regex.named_captures(@alias_regex, local) do
      %{"id" => id} when byte_size(id) >= 8 -> id
      _ -> nil
    end
  end

  @doc """
  Scanne plusieurs adresses (To + Cc + Bcc d'un payload webhook) et renvoie
  le premier incident_id matchant, ou `nil`.
  """
  def extract_incident_id_from_recipients(addresses) when is_list(addresses) do
    addresses
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&extract_incident_id/1)
  end

  def extract_incident_id_from_recipients(_), do: nil
end
