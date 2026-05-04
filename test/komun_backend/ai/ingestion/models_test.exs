defmodule KomunBackend.AI.Ingestion.ModelsTest do
  use ExUnit.Case, async: true

  alias KomunBackend.AI.Ingestion.Models

  test "list/0 expose au moins les modèles attendus" do
    ids = Models.list() |> Enum.map(& &1.id)
    assert "claude-opus-4-7" in ids
    assert "claude-sonnet-4-6" in ids
    assert "deepseek-v4-flash" in ids
  end

  test "get/1 trouve un modèle existant" do
    assert %{id: "deepseek-v4-flash", provider: :deepseek} = Models.get("deepseek-v4-flash")
  end

  test "get/1 renvoie nil pour un id inconnu" do
    assert is_nil(Models.get("ghost-model"))
  end

  test "fetch!/1 lève pour un id inconnu" do
    assert_raise ArgumentError, fn -> Models.fetch!("ghost-model") end
  end

  describe "estimate_cost/3" do
    test "Opus 4.7 sur 1M input + 1M output = $15 + $75 = $90" do
      assert Models.estimate_cost("claude-opus-4-7", 1_000_000, 1_000_000) == 90.0
    end

    test "DeepSeek Flash sur 6500 input + 3000 output ≈ $0.0017" do
      cost = Models.estimate_cost("deepseek-v4-flash", 6500, 3000)
      assert_in_delta cost, 0.001750, 0.000001
    end

    test "tokens à 0 → coût 0" do
      assert Models.estimate_cost("claude-opus-4-7", 0, 0) == 0.0
    end
  end

  test "default_id/0 renvoie un modèle déclaré dans le registre" do
    assert Models.get(Models.default_id())
  end
end
