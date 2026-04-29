defmodule KomunBackend.AI.IngestionDispatcherTest do
  @moduledoc """
  Couvre le dispatcher AI qui relaie le webhook Resend tel quel vers
  une routine Claude distante. Pas de réseau réel : `Req.Test` stub via
  le plug configuré par `:ingestion_dispatcher_req_options`.
  """

  use ExUnit.Case, async: false

  alias KomunBackend.AI.IngestionDispatcher

  @stub_name __MODULE__

  setup do
    previous_options =
      Application.get_env(:komun_backend, :ingestion_dispatcher_req_options, [])

    Application.put_env(
      :komun_backend,
      :ingestion_dispatcher_req_options,
      plug: {Req.Test, @stub_name}
    )

    on_exit(fn ->
      Application.put_env(
        :komun_backend,
        :ingestion_dispatcher_req_options,
        previous_options
      )
    end)

    :ok
  end

  describe "dispatch/3" do
    test "POSTs the payload as JSON with bearer auth and returns :ok on 2xx" do
      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, {:routine_request, conn})
        Req.Test.json(conn, %{ok: true})
      end)

      payload = %{
        "from" => %{"email" => "x@y.z"},
        "subject" => "Test"
      }

      assert :ok ==
               IngestionDispatcher.dispatch(
                 "https://routine.example/trigger",
                 "test-token",
                 payload
               )

      assert_received {:routine_request, conn}
      assert ["Bearer test-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
      # Anthropic beta gate + version pin for /v1/claude_code/routines/.../fire
      assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")

      assert ["experimental-cc-routine-2026-04-01"] =
               Plug.Conn.get_req_header(conn, "anthropic-beta")

      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["subject"] == "Test"
    end

    test "returns :error on 4xx/5xx" do
      Req.Test.stub(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{error: "boom"})
      end)

      assert :error ==
               IngestionDispatcher.dispatch(
                 "https://routine.example/trigger",
                 "tok",
                 %{"event" => "x"}
               )
    end
  end

  describe "dispatch_async/1" do
    test "is a no-op when env vars are missing" do
      previous_url = System.get_env("KOMUN_INGEST_TRIGGER_URL")
      previous_token = System.get_env("KOMUN_INGEST_TRIGGER_TOKEN")
      System.delete_env("KOMUN_INGEST_TRIGGER_URL")
      System.delete_env("KOMUN_INGEST_TRIGGER_TOKEN")

      on_exit(fn ->
        if previous_url,
          do: System.put_env("KOMUN_INGEST_TRIGGER_URL", previous_url),
          else: System.delete_env("KOMUN_INGEST_TRIGGER_URL")

        if previous_token,
          do: System.put_env("KOMUN_INGEST_TRIGGER_TOKEN", previous_token),
          else: System.delete_env("KOMUN_INGEST_TRIGGER_TOKEN")
      end)

      assert :noop == IngestionDispatcher.dispatch_async(%{"event" => "x"})
    end

    test "starts a supervised task when env vars are set" do
      System.put_env("KOMUN_INGEST_TRIGGER_URL", "https://routine.example/trigger")
      System.put_env("KOMUN_INGEST_TRIGGER_TOKEN", "tok")

      on_exit(fn ->
        System.delete_env("KOMUN_INGEST_TRIGGER_URL")
        System.delete_env("KOMUN_INGEST_TRIGGER_TOKEN")
      end)

      # We don't assert the HTTP call here because the Task spawned by
      # `dispatch_async/1` runs under TaskSupervisor and inherits its own
      # process dictionary — wiring `Req.Test` allowance through that is
      # flaky. The HTTP-call assertion lives in the synchronous
      # `dispatch/3` test above; here we only verify the supervisor
      # child is started.
      assert {:ok, pid} = IngestionDispatcher.dispatch_async(%{"event" => "x"})
      assert is_pid(pid)
    end
  end
end
