defmodule KomunBackend.AssistantTest do
  use ExUnit.Case, async: true

  alias KomunBackend.Assistant

  describe "rate_limit_window_hours/0" do
    test "is 24 so the cron window matches the UX copy" do
      assert Assistant.rate_limit_window_hours() == 24
    end
  end

  describe "next_allowed_at/1" do
    test "returns now-ish when the user has never chatted" do
      now = DateTime.utc_now()
      ret = Assistant.next_allowed_at(%{last_chat_at: nil})
      # Within 2 seconds of now — enough slack for slow CI.
      assert abs(DateTime.diff(ret, now, :second)) <= 2
    end

    test "returns 24h after last_chat_at when a previous chat exists" do
      last = ~U[2026-04-21 10:00:00Z]
      assert Assistant.next_allowed_at(%{last_chat_at: last}) ==
               ~U[2026-04-22 10:00:00Z]
    end

    test "falls back to now for unknown shapes" do
      now = DateTime.utc_now()
      ret = Assistant.next_allowed_at(:bad)
      assert abs(DateTime.diff(ret, now, :second)) <= 2
    end
  end

  describe "ask/3 without network" do
    test "rejects an empty question before touching Groq" do
      assert {:error, :empty_question} =
               Assistant.ask(
                 %{id: "u", role: :coproprietaire, last_chat_at: nil},
                 "b",
                 ""
               )

      assert {:error, :empty_question} =
               Assistant.ask(
                 %{id: "u", role: :coproprietaire, last_chat_at: nil},
                 "b",
                 "   "
               )
    end

    test "rejects a question over 2000 characters" do
      too_long = String.duplicate("a", 2001)

      assert {:error, :question_too_long} =
               Assistant.ask(
                 %{id: "u", role: :coproprietaire, last_chat_at: nil},
                 "b",
                 too_long
               )
    end
  end
end
