defmodule KomunBackendWeb.AiCompareControllerTest do
  @moduledoc """
  Couvre les endpoints admin de comparaison de modèles AI.

  Le `Runner` est testé indépendamment dans `RunnerTest` — ici on
  valide l'authz, le format de la requête / réponse, et le routage
  des erreurs validation (modèle inconnu, messages invalides).
  """

  use KomunBackendWeb.ConnCase, async: false

  alias KomunBackend.Repo
  alias KomunBackend.Accounts.User
  alias KomunBackend.Auth.Guardian

  @anthropic_stub :ai_compare_anthropic_stub
  @deepseek_stub :ai_compare_deepseek_stub

  setup do
    Application.put_env(:komun_backend, :anthropic_req_options, plug: {Req.Test, @anthropic_stub})
    Application.put_env(:komun_backend, :deepseek_req_options, plug: {Req.Test, @deepseek_stub})

    System.put_env("ANTHROPIC_API_KEY", "sk-ant-fake")
    System.put_env("DEEPSEEK_API_KEY", "sk-deepseek-fake")

    on_exit(fn ->
      Application.delete_env(:komun_backend, :anthropic_req_options)
      Application.delete_env(:komun_backend, :deepseek_req_options)
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("DEEPSEEK_API_KEY")
    end)

    :ok
  end

  defp insert_user!(role) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
  end

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.sign_in(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "GET /admin/ai/models" do
    test "renvoie la liste des modèles supportés à un super_admin", %{conn: conn} do
      admin = insert_user!(:super_admin)

      conn = conn |> authed(admin) |> get(~p"/api/v1/admin/ai/models")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      ids = body["data"] |> Enum.map(& &1["id"])
      assert "claude-opus-4-7" in ids
      assert "deepseek-v4-flash" in ids
      assert is_binary(body["default_id"])
    end

    test "renvoie 403 à un copropriétaire", %{conn: conn} do
      copro = insert_user!(:coproprietaire)
      conn = conn |> authed(copro) |> get(~p"/api/v1/admin/ai/models")
      assert json_response(conn, 403)
    end
  end

  describe "POST /admin/ai/compare-ingestion" do
    setup do
      admin = insert_user!(:super_admin)
      {:ok, admin: admin}
    end

    test "lance plusieurs modèles en parallèle et renvoie tous les résultats", %{conn: conn, admin: admin} do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "Réponse Opus"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })
      end)

      Req.Test.stub(@deepseek_stub, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"content" => "Réponse DS"}, "finish_reason" => "stop"}
          ],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
        })
      end)

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/admin/ai/compare-ingestion", %{
          "model_ids" => ["claude-opus-4-7", "deepseek-v4-flash"],
          "messages" => [
            %{"role" => "system", "content" => "Tu es un agent."},
            %{"role" => "user", "content" => "L'ascenseur est en panne."}
          ]
        })

      body = json_response(conn, 200)
      results = body["results"]

      assert results["claude-opus-4-7"]["ok"] == true
      assert results["claude-opus-4-7"]["content"] == "Réponse Opus"
      assert results["claude-opus-4-7"]["input_tokens"] == 100
      assert results["claude-opus-4-7"]["cost_usd"] > 0

      assert results["deepseek-v4-flash"]["ok"] == true
      assert results["deepseek-v4-flash"]["content"] == "Réponse DS"
      # Le coût DeepSeek doit être bien plus petit que celui d'Opus pour
      # les mêmes tokens — c'est le cœur du test métier.
      assert results["deepseek-v4-flash"]["cost_usd"] <
               results["claude-opus-4-7"]["cost_usd"]
    end

    test "ne plante pas si un modèle échoue : renvoie ok=false sur la mauvaise entrée", %{conn: conn, admin: admin} do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })
      end)

      Req.Test.stub(@deepseek_stub, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/admin/ai/compare-ingestion", %{
          "model_ids" => ["claude-opus-4-7", "deepseek-v4-flash"],
          "messages" => [%{"role" => "user", "content" => "x"}]
        })

      body = json_response(conn, 200)
      assert body["results"]["claude-opus-4-7"]["ok"] == true
      assert body["results"]["deepseek-v4-flash"]["ok"] == false
      assert body["results"]["deepseek-v4-flash"]["error"] =~ "503"
    end

    test "renvoie 422 sur un model_id inconnu", %{conn: conn, admin: admin} do
      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/admin/ai/compare-ingestion", %{
          "model_ids" => ["ghost-model"],
          "messages" => [%{"role" => "user", "content" => "x"}]
        })

      body = json_response(conn, 422)
      assert body["error"] =~ "ghost-model"
    end

    test "renvoie 422 sur des messages malformés", %{conn: conn, admin: admin} do
      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/v1/admin/ai/compare-ingestion", %{
          "model_ids" => ["claude-opus-4-7"],
          "messages" => [%{"role" => "wrong", "content" => "x"}]
        })

      assert json_response(conn, 422)
    end

    test "renvoie 403 à un copropriétaire", %{conn: conn} do
      copro = insert_user!(:coproprietaire)

      conn =
        conn
        |> authed(copro)
        |> post(~p"/api/v1/admin/ai/compare-ingestion", %{
          "model_ids" => ["claude-opus-4-7"],
          "messages" => [%{"role" => "user", "content" => "x"}]
        })

      assert json_response(conn, 403)
    end
  end
end
