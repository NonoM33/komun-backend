defmodule KomunBackendWeb.ConsentController do
  use KomunBackendWeb, :controller

  alias KomunBackend.Consents

  @valid_sources ~w(banner_all banner_essential banner_custom settings withdraw)

  def create(conn, params) do
    source = to_string(params["source"] || "")

    if source not in @valid_sources do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "invalid source"})
    else
      categories = normalize_categories(source, params["categories"] || %{})
      user = Guardian.Plug.current_resource(conn)

      attrs = %{
        "user_id" => user && user.id,
        "organization_id" => user && Map.get(user, :organization_id),
        "visitor_id" => params["visitor_id"],
        "essential" => true,
        "analytics" => categories.analytics,
        "session_replay" => categories.session_replay,
        "marketing" => categories.marketing,
        "source" => source,
        "ip_address" => conn.remote_ip |> :inet.ntoa() |> to_string(),
        "user_agent" => get_req_header(conn, "user-agent") |> List.first()
      }

      case Consents.record_consent(attrs) do
        {:ok, log} ->
          json(conn, %{
            ok: true,
            policy_version: log.policy_version,
            categories: %{
              essential: log.essential,
              analytics: log.analytics,
              session_replay: log.session_replay,
              marketing: log.marketing
            }
          })

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: translate_errors(changeset)})
      end
    end
  end

  defp normalize_categories("banner_all", _),
    do: %{analytics: true, session_replay: true, marketing: true}

  defp normalize_categories(src, _) when src in ["banner_essential", "withdraw"],
    do: %{analytics: false, session_replay: false, marketing: false}

  defp normalize_categories(_, raw) when is_map(raw) do
    %{
      analytics: truthy(raw["analytics"]),
      session_replay: truthy(raw["session_replay"]),
      marketing: truthy(raw["marketing"])
    }
  end

  defp normalize_categories(_, _), do: %{analytics: false, session_replay: false, marketing: false}

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("1"), do: true
  defp truthy(1), do: true
  defp truthy(_), do: false

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
