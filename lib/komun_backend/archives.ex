defmodule KomunBackend.Archives do
  @moduledoc """
  Contexte Archives : données historiques importées depuis l'ancienne
  stack Rails (votes CS, …). Strictement read-only côté app, sauf
  l'endpoint admin d'import qui upsert via `import_council_votes/2`.
  """

  import Ecto.Query
  alias KomunBackend.Repo
  alias KomunBackend.Archives.ArchivedCouncilVote

  # ── Reads ────────────────────────────────────────────────────────────────

  @doc """
  Liste les votes archivés. Si `residence_id` est donné, on scope ;
  sinon on remonte tout (super_admin only côté controller).
  """
  def list_council_votes(opts \\ []) do
    q = from(v in ArchivedCouncilVote, order_by: [desc: v.legacy_created_at])

    q =
      case Keyword.get(opts, :residence_id) do
        nil -> q
        rid -> from(v in q, where: v.residence_id == ^rid)
      end

    Repo.all(q)
  end

  # ── Import ──────────────────────────────────────────────────────────────

  @doc """
  Upsert bulk à partir d'une liste de maps (JSON-decoded). Idempotent
  grâce à l'unique_index sur `legacy_id`. Renvoie le nombre de votes
  insérés/mis à jour.

  Forme attendue par vote :
    %{
      "legacy_id" => "42",
      "title" => "Élection du président du CS 2024",
      "description" => "…",
      "vote_type" => "election",
      "status" => "closed",
      "anonymous" => true,
      "options" => [
        %{"text" => "Renaud", "votes_count" => 3},
        %{"text" => "Pascale", "votes_count" => 1}
      ],
      "total_votes" => 4,
      "winning_option_text" => "Renaud",
      "starts_at" => "2024-05-10T09:00:00Z",
      "ends_at" => "2024-05-20T09:00:00Z",
      "closed_at" => "2024-05-20T09:00:00Z",
      "legacy_created_at" => "2024-05-01T08:00:00Z",
      "residence_id" => "<uuid>" # optionnel
    }
  """
  def import_council_votes(votes, opts \\ []) when is_list(votes) do
    residence_id_override = Keyword.get(opts, :residence_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    results =
      Enum.map(votes, fn v ->
        attrs = normalize(v, residence_id_override)

        # Upsert manuel : si legacy_id existe déjà, on update les champs
        # clés (title/status/options/total_votes). Sinon insert.
        existing =
          from(a in ArchivedCouncilVote, where: a.legacy_id == ^attrs.legacy_id)
          |> Repo.one()

        changeset =
          (existing || %ArchivedCouncilVote{})
          |> ArchivedCouncilVote.changeset(attrs |> Map.put(:updated_at, now))

        case existing do
          nil -> Repo.insert(changeset)
          _ -> Repo.update(changeset)
        end
      end)

    inserted = Enum.count(results, &match?({:ok, _}, &1))
    errors = for {:error, cs} <- results, do: cs

    {:ok, %{imported: inserted, errors: Enum.map(errors, &changeset_error_summary/1)}}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp normalize(v, residence_id_override) when is_map(v) do
    %{
      legacy_id: to_string(fetch(v, ["legacy_id", "id"])),
      title: fetch(v, ["title"]),
      description: fetch(v, ["description"]),
      vote_type: to_str(fetch(v, ["vote_type"])),
      status: to_str(fetch(v, ["status"])),
      anonymous: !!fetch(v, ["anonymous"]),
      options: normalize_options(fetch(v, ["options"]) || []),
      total_votes: to_int(fetch(v, ["total_votes"])) || 0,
      winning_option_text: fetch(v, ["winning_option_text"]),
      starts_at: parse_dt(fetch(v, ["starts_at"])),
      ends_at: parse_dt(fetch(v, ["ends_at"])),
      closed_at: parse_dt(fetch(v, ["closed_at"])),
      legacy_created_at:
        parse_dt(fetch(v, ["legacy_created_at", "created_at"])) ||
          DateTime.utc_now() |> DateTime.truncate(:second),
      residence_id: residence_id_override || fetch(v, ["residence_id"])
    }
  end

  defp fetch(map, keys) do
    Enum.find_value(keys, fn k -> Map.get(map, k) end)
  end

  defp normalize_options(opts) when is_list(opts) do
    Enum.map(opts, fn
      o when is_map(o) ->
        %{
          "text" => fetch(o, ["text", "label"]) || "",
          "votes_count" => to_int(fetch(o, ["votes_count", "count"])) || 0,
          "weighted_votes" => to_int(fetch(o, ["weighted_votes"])) || 0,
          "position" => to_int(fetch(o, ["position"])) || 0
        }

      other ->
        %{"text" => to_string(other), "votes_count" => 0}
    end)
  end

  defp normalize_options(_), do: []

  defp to_str(nil), do: nil
  defp to_str(s) when is_binary(s), do: s
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(n), do: to_string(n)

  defp to_int(nil), do: nil
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> v
      :error -> nil
    end
  end
  defp to_int(_), do: nil

  defp parse_dt(nil), do: nil
  defp parse_dt(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp changeset_error_summary(cs) do
    cs.errors
    |> Enum.map(fn {k, {msg, _}} -> "#{k}: #{msg}" end)
    |> Enum.join(", ")
  end
end
