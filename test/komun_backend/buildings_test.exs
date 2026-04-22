defmodule KomunBackend.BuildingsTest do
  use ExUnit.Case, async: true

  alias KomunBackend.Buildings

  describe "generate_join_code/0" do
    test "returns an 8-char uppercase alphanumeric string" do
      code = Buildings.generate_join_code()
      assert is_binary(code)
      assert String.length(code) == 8
      assert code == String.upcase(code)
      assert String.match?(code, ~r/^[A-Z2-9]+$/)
    end

    test "is effectively random across 500 samples" do
      codes = for _ <- 1..500, do: Buildings.generate_join_code()
      # A clash below 500 samples in a ~32^8 space would be a clear bug.
      assert codes |> Enum.uniq() |> length() == 500
    end

    test "never produces the ambiguous characters 0, 1, O, I" do
      for _ <- 1..200 do
        code = Buildings.generate_join_code()
        refute String.contains?(code, "0")
        refute String.contains?(code, "1")
        refute String.contains?(code, "O")
        refute String.contains?(code, "I")
      end
    end
  end

  describe "get_building_by_join_code/1" do
    test "returns nil for non-binary input" do
      assert Buildings.get_building_by_join_code(nil) == nil
      assert Buildings.get_building_by_join_code(123) == nil
    end
  end
end
