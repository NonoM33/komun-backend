defmodule KomunBackend.AI.Ingestion.RunnerTest do
  @moduledoc """
  Couvre le runner unifié + les deux providers (Anthropic, DeepSeek)
  via `Req.Test`. Le focus est :

    * dispatch correct vers le bon provider selon `model_id`
    * format de la requête sortante (path, headers, body)
    * parsing de la réponse (content + tokens)
    * calcul du coût USD à partir des tokens et du registre
    * `run_many/3` lance les modèles en parallèle et tolère les échecs
  """

  use ExUnit.Case, async: false

  alias KomunBackend.AI.Ingestion.Runner

  @anthropic_stub :ai_anthropic_stub
  @deepseek_stub :ai_deepseek_stub

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

  describe "run/3 — Anthropic" do
    test "dispatche vers Anthropic + parse content + calcule coût" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        # Vérifie l'en-tête anthropic-version + l'API key
        assert ["sk-ant-fake"] = Plug.Conn.get_req_header(conn, "x-api-key")
        assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")

        Req.Test.json(conn, %{
          "id" => "msg_1",
          "model" => "claude-opus-4-7",
          "content" => [%{"type" => "text", "text" => "Réponse Opus."}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })
      end)

      messages = [
        %{role: "system", content: "Tu es un agent."},
        %{role: "user", content: "Hello."}
      ]

      assert {:ok, res} = Runner.run("claude-opus-4-7", messages)
      assert res.model == "claude-opus-4-7"
      assert res.provider == :anthropic
      assert res.content == "Réponse Opus."
      assert res.input_tokens == 100
      assert res.output_tokens == 50
      assert res.finish_reason == "end_turn"

      # Coût : 100 × 15 / 1M + 50 × 75 / 1M = 0.0015 + 0.00375 = 0.00525
      assert_in_delta res.cost_usd, 0.00525, 0.000001

      assert res.response_ms >= 0
    end

    test "extrait le system du début des messages et le passe en top-level" do
      test_pid = self()

      Req.Test.stub(@anthropic_stub, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        })
      end)

      Runner.run("claude-opus-4-7", [
        %{role: "system", content: "système"},
        %{role: "user", content: "user"}
      ])

      assert_received {:body, body}
      assert body["system"] == "système"
      assert body["messages"] == [%{"role" => "user", "content" => "user"}]
    end
  end

  describe "run/3 — DeepSeek" do
    test "dispatche vers DeepSeek + mappe model_id sur deepseek-chat" do
      test_pid = self()

      Req.Test.stub(@deepseek_stub, fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(body)})

        assert ["Bearer sk-deepseek-fake"] = Plug.Conn.get_req_header(conn, "authorization")

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "DS reply"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 200, "completion_tokens" => 100}
        })
      end)

      assert {:ok, res} = Runner.run("deepseek-v4-flash", [%{role: "user", content: "Salut"}])
      assert res.model == "deepseek-v4-flash"
      assert res.provider == :deepseek
      assert res.content == "DS reply"
      assert res.input_tokens == 200
      assert res.output_tokens == 100

      # 200 × 0.14 / 1M + 100 × 0.28 / 1M = 0.000028 + 0.000028 = 0.000056
      assert_in_delta res.cost_usd, 0.000056, 0.000001

      assert_received {:body, body}
      # Le model envoyé à DeepSeek doit être leur nom interne, pas l'id Komun
      assert body["model"] == "deepseek-chat"
    end
  end

  test "run/3 renvoie {:error, :unknown_model} pour un id non déclaré" do
    assert {:error, {:unknown_model, "ghost-model"}} =
             Runner.run("ghost-model", [%{role: "user", content: "x"}])
  end

  test "run/3 propage l'erreur du provider en cas de 5xx upstream" do
    Req.Test.stub(@anthropic_stub, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => "overloaded"})
    end)

    assert {:error, {:http_error, 503, _}} =
             Runner.run("claude-opus-4-7", [%{role: "user", content: "x"}])
  end

  describe "run_many/3" do
    test "lance plusieurs modèles en parallèle et renvoie tous les résultats" do
      Req.Test.stub(@anthropic_stub, fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "anthr"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })
      end)

      Req.Test.stub(@deepseek_stub, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"content" => "ds"}, "finish_reason" => "stop"}
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
        })
      end)

      results =
        Runner.run_many(
          ["claude-opus-4-7", "deepseek-v4-flash"],
          [%{role: "user", content: "salut"}]
        )

      assert {:ok, %{content: "anthr"}} = results["claude-opus-4-7"]
      assert {:ok, %{content: "ds"}} = results["deepseek-v4-flash"]
    end
  end
end
