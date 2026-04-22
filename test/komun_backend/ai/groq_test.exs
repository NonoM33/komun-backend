defmodule KomunBackend.AI.GroqTest do
  use ExUnit.Case, async: true

  alias KomunBackend.AI.Groq

  describe "complete/2 without an API key" do
    test "short-circuits with {:error, :missing_api_key} so tests never hit the network" do
      messages = [%{role: :user, content: "hello"}]
      assert {:error, :missing_api_key} = Groq.complete(messages, api_key: "")
      assert {:error, :missing_api_key} = Groq.complete(messages, api_key: nil)
    end
  end
end
