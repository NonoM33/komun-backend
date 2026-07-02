defmodule KomunBackendWeb.ErrorLeakGuardTest do
  @moduledoc """
  Non-régression sécurité — remédiation audit 2026-07-02.

  Certains controllers renvoyaient au client `json(%{error: inspect(reason)})`,
  exposant des structs Ecto / erreurs internes brutes (fuite d'informations).

  Ces branches `{:error, reason}` sont des filets de sécurité pour des
  erreurs internes inattendues : elles ne sont pas déclenchables de façon
  déterministe via une requête HTTP normale (les contexts ne renvoient que
  des changesets ou des atomes connus). On garde donc un test au niveau du
  code source qui échoue dès que quelqu'un ré-introduit le motif de fuite
  dans le corps d'une réponse client.

  Le motif toléré : `inspect(reason)` UNIQUEMENT à l'intérieur d'un
  `Logger.error(...)` (log serveur), jamais dans un `json(%{error: ...})`.
  """

  use ExUnit.Case, async: true

  @controllers ~w(admin diligence battle event)

  defp source(name) do
    Path.join([
      File.cwd!(),
      "lib",
      "komun_backend_web",
      "controllers",
      "#{name}_controller.ex"
    ])
    |> File.read!()
  end

  for name <- @controllers do
    test "#{name}_controller ne renvoie jamais inspect(reason) dans un corps json client" do
      src = source(unquote(name))

      # Fuite directe : json(%{error: inspect(reason)})
      refute src =~ ~r/json\(%\{error:\s*inspect\(reason\)\}\)/,
             "#{unquote(name)}_controller expose inspect(reason) brut au client"

      # Fuite interpolée : json(%{error: "... #{inspect(reason)}"})
      refute src =~ ~r/json\(%\{error:\s*"[^"]*#\{inspect\(reason\)\}/,
             "#{unquote(name)}_controller interpole inspect(reason) dans un message client"
    end

    test "#{name}_controller logge bien les erreurs internes côté serveur" do
      src = source(unquote(name))

      if src =~ "inspect(reason)" do
        assert src =~ ~r/Logger\.(error|warning)\(/,
               "#{unquote(name)}_controller utilise inspect(reason) sans le journaliser via Logger"
      end
    end
  end
end
