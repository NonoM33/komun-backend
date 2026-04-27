defmodule KomunBackend.Assistant.Rules do
  @moduledoc """
  Context module for managing the per-building custom prompt rules used by
  the AI assistant. Centralises the CRUD and the system-prompt assembly so
  the rest of the codebase doesn't have to know about the schema layout.

  The active rules (sorted by `position`) are concatenated under a clearly
  marked block at the end of the base system prompt — that lets the model
  treat them as residence-specific overrides without losing the safety
  rails of the base prompt (no fabrication, French only, etc.).
  """

  import Ecto.Query

  alias KomunBackend.Assistant.Rule
  alias KomunBackend.Repo

  @doc "All rules of a building, ordered for the admin UI."
  def list_rules(building_id) do
    from(r in Rule,
      where: r.building_id == ^building_id,
      order_by: [asc: r.position, asc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Active rules of a building, used at prompt assembly time. We exclude
  disabled ones server-side so the LLM never sees them, even by accident.
  """
  def list_active_rules(building_id) do
    from(r in Rule,
      where: r.building_id == ^building_id and r.enabled == true,
      order_by: [asc: r.position, asc: r.inserted_at]
    )
    |> Repo.all()
  end

  def get_rule(id) do
    case Repo.get(Rule, id) do
      nil -> {:error, :not_found}
      rule -> {:ok, rule}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get_rule!(id), do: Repo.get!(Rule, id)

  @doc """
  Creates a rule for `building_id`. The `position` defaults to "last",
  so a new rule lands at the bottom of the admin list and at the bottom
  of the prompt block (lowest priority unless the admin reorders).
  """
  def create_rule(building_id, created_by_user_id, attrs) do
    next_pos = next_position(building_id)

    full_attrs =
      attrs
      |> Map.put("building_id", building_id)
      |> Map.put("created_by_user_id", created_by_user_id)
      |> Map.put_new("position", next_pos)

    %Rule{}
    |> Rule.changeset(full_attrs)
    |> Repo.insert()
  end

  def update_rule(%Rule{} = rule, attrs) do
    rule
    |> Rule.changeset(attrs)
    |> Repo.update()
  end

  def delete_rule(%Rule{} = rule), do: Repo.delete(rule)

  @doc """
  Builds the final system prompt by appending the residence's active
  rules to `base_prompt`. Returns `base_prompt` unchanged when the
  building has no enabled rule, so behaviour is identical to the
  pre-feature baseline for buildings that haven't opted in.
  """
  def build_system_prompt(base_prompt, []), do: base_prompt

  def build_system_prompt(base_prompt, rules) when is_list(rules) do
    bullets =
      rules
      |> Enum.map(&("- " <> &1.content))
      |> Enum.join("\n")

    """
    #{base_prompt}

    Règles spécifiques à cette résidence (à appliquer en priorité, elles
    complètent le règlement de copropriété indexé) :
    #{bullets}
    """
  end

  defp next_position(building_id) do
    case Repo.one(
           from(r in Rule,
             where: r.building_id == ^building_id,
             select: max(r.position)
           )
         ) do
      nil -> 0
      max -> max + 1
    end
  end
end
