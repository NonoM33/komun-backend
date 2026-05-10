defmodule KomunBackend.Notifications.Jobs.EventContributionGapJob do
  @moduledoc """
  Push « il manque encore X » envoyé J-3 aux membres du scope qui n'ont
  pas encore claim de contribution, **uniquement si** au moins une
  contribution a un `claimed_quantity < needed_quantity` (gap réel).

  Pas d'email, juste push (le but est de pousser doucement, sans inonder).
  """

  use Oban.Worker, queue: :push_notifications, max_attempts: 3

  alias KomunBackend.{Events, Notifications, Repo}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.{Building, BuildingMember}
  alias KomunBackend.Events.{Event, EventBuildingScope, EventEmailBlast,
                              EventContribution, EventContributionClaim}

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id}}) do
    case Repo.get(Event, event_id) do
      nil ->
        :ok

      %Event{status: :cancelled} ->
        :ok

      %Event{status: :draft} ->
        :ok

      event ->
        do_gap(event)
    end
  end

  defp do_gap(event) do
    full = Events.get_event!(event.id)

    gaps = compute_gaps(full)

    if gaps == [] do
      :ok
    else
      summary = build_summary(gaps)
      target_user_ids = compute_target_users(full)

      users =
        from(u in User, where: u.id in ^target_user_ids and u.push_tokens != ^[])
        |> Repo.all()

      Enum.each(users, fn u ->
        Notifications.send_to_user(
          u,
          "Il manque encore quelque chose pour #{full.title}",
          summary,
          %{type: "event_gap", event_id: full.id}
        )
      end)

      %EventEmailBlast{}
      |> EventEmailBlast.changeset(%{
        event_id: full.id,
        kind: :gap_j3,
        recipient_count: length(users),
        subject: summary
      })
      |> Repo.insert()
    end
  end

  defp compute_gaps(event) do
    Enum.filter(event.contributions, fn %EventContribution{} = c ->
      need = c.needed_quantity || 0
      claimed = sum_claims(c)
      need > 0 and claimed < need
    end)
  end

  defp sum_claims(%EventContribution{claims: claims}) do
    case claims do
      list when is_list(list) ->
        Enum.reduce(list, 0, fn %EventContributionClaim{quantity: q}, acc ->
          acc + (q || 0)
        end)

      _ ->
        0
    end
  end

  defp build_summary([single]) do
    n = (single.needed_quantity || 0) - sum_claims(single)
    "Il manque encore #{n} #{single.title}"
  end

  defp build_summary(gaps) when length(gaps) > 1 do
    "Il manque encore plusieurs choses (#{length(gaps)} apports incomplets) — un coup de main ?"
  end

  defp compute_target_users(%Event{} = event) do
    # Membres du scope (résidence ou bâtiments listés) qui n'ont PAS
    # déjà claim une contribution.
    scope_user_ids = scope_member_user_ids(event)
    already_claimed_ids =
      event.contributions
      |> Enum.flat_map(fn c ->
        case c.claims do
          list when is_list(list) -> Enum.map(list, & &1.user_id)
          _ -> []
        end
      end)
      |> MapSet.new()

    Enum.reject(scope_user_ids, &MapSet.member?(already_claimed_ids, &1))
  end

  defp scope_member_user_ids(%Event{building_scopes: scopes, residence_id: residence_id}) do
    case scopes do
      list when is_list(list) and list != [] ->
        building_ids = Enum.map(list, & &1.building_id)

        from(m in BuildingMember,
          where: m.building_id in ^building_ids and m.is_active == true,
          select: m.user_id,
          distinct: true
        )
        |> Repo.all()

      _ ->
        from(m in BuildingMember,
          join: b in Building,
          on: b.id == m.building_id,
          where: b.residence_id == ^residence_id and m.is_active == true,
          select: m.user_id,
          distinct: true
        )
        |> Repo.all()
    end
  end
end
