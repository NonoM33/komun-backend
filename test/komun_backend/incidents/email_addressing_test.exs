defmodule KomunBackend.Incidents.EmailAddressingTest do
  use ExUnit.Case, async: false

  alias KomunBackend.Incidents.EmailAddressing

  describe "incident_alias/1" do
    setup do
      original = System.get_env("KOMUN_INBOX_DOMAIN")
      System.put_env("KOMUN_INBOX_DOMAIN", "inbox.komun.test")

      on_exit(fn ->
        if original, do: System.put_env("KOMUN_INBOX_DOMAIN", original), else: System.delete_env("KOMUN_INBOX_DOMAIN")
      end)

      :ok
    end

    test "uses configured inbox domain" do
      assert EmailAddressing.incident_alias("00000000-0000-0000-0000-000000000042") ==
               "incident-00000000-0000-0000-0000-000000000042@inbox.komun.test"
    end

    test "accepts a struct via :id" do
      assert EmailAddressing.incident_alias(%{id: "abc-123"}) =~ ~r/\Aincident-abc-123@/
    end
  end

  describe "extract_incident_id/1" do
    test "returns the UUID from the local part" do
      assert EmailAddressing.extract_incident_id(
               "incident-00000000-0000-0000-0000-000000000042@inbox.komun.app"
             ) == "00000000-0000-0000-0000-000000000042"
    end

    test "tolerates a +tag suffix" do
      assert EmailAddressing.extract_incident_id(
               "incident-00000000-0000-0000-0000-000000000042+nexity@inbox.komun.app"
             ) == "00000000-0000-0000-0000-000000000042"
    end

    test "is case-insensitive" do
      assert EmailAddressing.extract_incident_id(
               "INCIDENT-00000000-0000-0000-0000-000000000042@INBOX.KOMUN.APP"
             ) == "00000000-0000-0000-0000-000000000042"
    end

    test "returns nil for unrelated addresses" do
      assert EmailAddressing.extract_incident_id("foo@bar.com") == nil
    end

    test "returns nil for blank input" do
      assert EmailAddressing.extract_incident_id(nil) == nil
      assert EmailAddressing.extract_incident_id("") == nil
    end

    test "rejects too-short ids (collision risk)" do
      assert EmailAddressing.extract_incident_id("incident-42@x.y") == nil
    end
  end

  describe "extract_incident_id_from_recipients/1" do
    test "scans across multiple addresses and returns the first match" do
      assert EmailAddressing.extract_incident_id_from_recipients([
               "syndic@nexity.fr",
               "incident-00000000-0000-0000-0000-000000000012@inbox.komun.app",
               "noise@bar.com"
             ]) == "00000000-0000-0000-0000-000000000012"
    end

    test "returns nil if no recipient matches" do
      assert EmailAddressing.extract_incident_id_from_recipients(["a@b.c", "c@d.e"]) == nil
    end

    test "returns nil for nil input" do
      assert EmailAddressing.extract_incident_id_from_recipients(nil) == nil
    end
  end
end
