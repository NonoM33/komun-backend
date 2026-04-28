defmodule KomunBackend.AI.DoleanceDossierTruncationTest do
  @moduledoc """
  Régression : un courrier IA ne doit JAMAIS être persisté tronqué.

  Avant le fix, `Groq.complete/2` ignorait `finish_reason` et le
  module `DoleanceDossier` plafonnait à `max_tokens: 1400`. Une
  lettre formelle coupée au milieu d'une phrase
  (« …à compter de la ») était sauvegardée comme un succès.

  Ce test stubbe l'API Groq via `Req.Test` :

    1. Si la première réponse est tronquée (`finish_reason: "length"`)
       mais qu'un retry renvoie une lettre complète, le retry doit
       être déclenché et c'est la lettre **complète** qui est
       persistée.

    2. Si même le retry au budget maximum est tronqué, la fonction
       renvoie `{:error, :truncated}` et **rien** n'est sauvegardé
       sur la doléance.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, Doleances, Repo, Residences}
  alias KomunBackend.AI.DoleanceDossier
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Doleances.Doleance
  alias KomunBackend.Residences.Residence

  @stub_name __MODULE__

  setup do
    previous_key = System.get_env("GROQ_API_KEY")
    System.put_env("GROQ_API_KEY", "test_key")
    previous_options = Application.get_env(:komun_backend, :groq_req_options, [])
    Application.put_env(:komun_backend, :groq_req_options, plug: {Req.Test, @stub_name})

    on_exit(fn ->
      if previous_key,
        do: System.put_env("GROQ_API_KEY", previous_key),
        else: System.delete_env("GROQ_API_KEY")

      Application.put_env(:komun_backend, :groq_req_options, previous_options)
    end)

    :ok
  end

  defp insert_residence! do
    {:ok, r} =
      %Residence{}
      |> Residence.initial_changeset(%{
        name: "Résidence #{System.unique_integer([:positive])}",
        join_code: Residences.generate_join_code()
      })
      |> Repo.insert()

    r
  end

  defp insert_building!(residence) do
    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "12 rue de la Paix",
      city: "Paris",
      postal_code: "75002",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp insert_user! do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: :coproprietaire,
      first_name: "Pascale",
      last_name: "Michon"
    })
    |> Repo.insert!()
  end

  defp setup_doleance do
    residence = insert_residence!()
    building = insert_building!(residence)
    user = insert_user!()
    {:ok, _} = Buildings.add_member(building.id, user.id, :membre_cs)

    {:ok, doleance} =
      Doleances.create_doleance(building.id, user.id, %{
        "title" => "Trottoirs dégradés devant le parking",
        "description" => "Voirie dans un état de délabrement avancé.",
        "category" => "voirie_parking"
      })

    {user, doleance}
  end

  defp groq_response(content, finish_reason) do
    %{
      "choices" => [
        %{
          "message" => %{"content" => content, "role" => "assistant"},
          "finish_reason" => finish_reason
        }
      ],
      "model" => "openai/gpt-oss-120b",
      "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 100}
    }
  end

  describe "generate_letter/3 — protection contre la troncature" do
    test "retente avec un budget plus large quand la première réponse est tronquée et persiste la lettre complète" do
      {user, doleance} = setup_doleance()

      truncated_letter =
        "Madame, Monsieur,\n\nNous vous écrivons concernant la voirie. À compter de la"

      complete_letter =
        "Madame, Monsieur,\n\nLettre complète, formellement signée.\n\nCordialement."

      counter = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        cond do
          n == 1 -> Req.Test.json(conn, groq_response(truncated_letter, "length"))
          true -> Req.Test.json(conn, groq_response(complete_letter, "stop"))
        end
      end)

      assert {:ok, %Doleance{ai_letter: saved}} =
               DoleanceDossier.generate_letter(doleance, user.id)

      assert saved == complete_letter
      assert :counters.get(counter, 1) == 2
    end

    test "renvoie {:error, :truncated} et ne persiste RIEN si la troncature persiste après retry" do
      {user, doleance} = setup_doleance()

      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, groq_response("Lettre tronquée à compter de la", "length"))
      end)

      assert {:error, :truncated} =
               DoleanceDossier.generate_letter(doleance, user.id)

      reloaded = Repo.get!(Doleance, doleance.id)
      assert is_nil(reloaded.ai_letter)
      assert is_nil(reloaded.ai_letter_generated_at)
    end
  end
end
