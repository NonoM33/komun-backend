defmodule KomunBackend.InboundEmailsTest do
  @moduledoc """
  Couvre le flux complet d'ingestion d'un `.eml` avec pièces jointes.

  Exigences vérifiées :

    1. `EmlParser.extract_attachments/1` + `InboundEmails.ingest_email/4`
       créent un incident, persistent les bytes des PJ sur disque, et
       insèrent une ligne `incident_files` par PJ.
    2. Le placeholder « [Pièce jointe encodée…] » est strippé du
       commentaire 📧 quand au moins une PJ a été correctement attachée.
    3. Les mimes hors whitelist (zip…) sont ignorés ; les PJ trop
       grosses (> 15 Mo) aussi.
    4. Si AUCUNE PJ ne passe la policy, on garde le placeholder tel
       quel — l'utilisateur doit voir qu'une PJ a été perdue.

  Le routeur AI (`IncidentRouter`) tombe sur `:create` quand
  `GROQ_API_KEY` n'est pas définie, ce qui rend le test déterministe
  sans mock. Idem pour `EmailSummarizer` qui retourne `{:error, _}` →
  `fallback_description`.
  """

  use KomunBackend.DataCase, async: false

  alias KomunBackend.{Buildings, InboundEmails, Incidents, Residences}
  alias KomunBackend.Accounts.User
  alias KomunBackend.Buildings.Building
  alias KomunBackend.Incidents.LocalStorage
  alias KomunBackend.InboundEmails.EmlParser
  alias KomunBackend.Residences.Residence

  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
  @pdf_b64 "JVBERi0xLjQKJcOkw7zDtsOfCg=="
  @zip_b64 "UEsDBA=="

  setup do
    # `IncidentRouter.route/2` retourne `:create` quand la clé est vide.
    # `EmailSummarizer.summarize/2` lève {:error, …} → fallback neutre.
    System.delete_env("GROQ_API_KEY")
    :ok
  end

  defp insert_user!(role \\ :super_admin) do
    %User{}
    |> User.changeset(%{
      email: "user#{System.unique_integer([:positive])}@test.local",
      role: role
    })
    |> Repo.insert!()
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

  defp insert_building! do
    residence = insert_residence!()

    %Building{}
    |> Building.initial_changeset(%{
      name: "Bâtiment #{System.unique_integer([:positive])}",
      address: "2 rue des Lilas",
      city: "Paris",
      postal_code: "75015",
      residence_id: residence.id,
      join_code: Buildings.generate_join_code()
    })
    |> Repo.insert!()
  end

  defp build_eml(parts) do
    headers = [
      "From: Alice <alice@example.com>",
      "To: bob@example.com",
      "Subject: Plainte fuite",
      "Date: Mon, 27 Apr 2026 10:00:00 +0000",
      "MIME-Version: 1.0",
      "Content-Type: multipart/mixed; boundary=\"BOUND\""
    ]

    (headers ++ ["", ""] ++ parts ++ ["--BOUND--", ""])
    |> Enum.join("\r\n")
  end

  describe "ingest_email/4 with attachments" do
    test "attache PNG + PDF, skip ZIP, strip le placeholder" do
      building = insert_building!()
      user = insert_user!()

      raw =
        build_eml([
          "--BOUND",
          "Content-Type: text/plain; charset=utf-8",
          "Content-Transfer-Encoding: 7bit",
          "",
          "Le voisin a une fuite, voir photos.",
          "--BOUND",
          "Content-Type: image/png; name=\"fuite.png\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"fuite.png\"",
          "",
          @png_b64,
          "--BOUND",
          "Content-Type: application/pdf; name=\"devis.pdf\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"devis.pdf\"",
          "",
          @pdf_b64,
          "--BOUND",
          "Content-Type: application/zip; name=\"archive.zip\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"archive.zip\"",
          "",
          @zip_b64
        ])

      email = EmlParser.parse(raw)
      attachments = EmlParser.extract_attachments(raw)

      # Sanity check : on injecte volontairement un placeholder dans le
      # body simulé (le vrai parser ne le mettrait pas pour ce cas, mais
      # on veut tester le strip dans `ingest_email`).
      placeholder = EmlParser.placeholder_attachment_text()
      email = Map.put(email, :body, email.body <> "\n\n" <> placeholder)

      assert {:ok, %{action: :create, incident_id: incident_id, attachments_count: 2}} =
               InboundEmails.ingest_email(building.id, user.id, email, attachments)

      incident = Incidents.get_incident!(incident_id)
      filenames = Enum.map(incident.files, & &1.filename) |> Enum.sort()
      assert filenames == ["devis.pdf", "fuite.png"]

      png_file = Enum.find(incident.files, &(&1.filename == "fuite.png"))
      assert png_file.kind == :photo
      assert png_file.mime_type == "image/png"
      assert png_file.file_size_bytes == 68

      pdf_file = Enum.find(incident.files, &(&1.filename == "devis.pdf"))
      assert pdf_file.kind == :document
      assert pdf_file.mime_type == "application/pdf"

      # Les bytes ont été écrits dans priv/static/uploads/incidents/<id>/.
      abs_path =
        Application.app_dir(
          :komun_backend,
          Path.join("priv/static", String.trim_leading(png_file.file_url, "/"))
        )

      assert File.exists?(abs_path)
      assert binary_part(File.read!(abs_path), 0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>

      # Le commentaire 📧 ne doit plus contenir le placeholder.
      [comment | _] = incident.comments
      refute String.contains?(comment.body, placeholder)
      assert comment.body =~ "Le voisin a une fuite"

      # Cleanup disque pour ne pas laisser des fichiers entre tests.
      File.rm_rf!(Path.dirname(abs_path))
    end

    test "garde le placeholder dans le commentaire si aucune PJ ne passe la policy" do
      building = insert_building!()
      user = insert_user!()

      raw =
        build_eml([
          "--BOUND",
          "Content-Type: text/plain; charset=utf-8",
          "",
          "Pas de photo lisible.",
          "--BOUND",
          "Content-Type: application/zip; name=\"archive.zip\"",
          "Content-Transfer-Encoding: base64",
          "Content-Disposition: attachment; filename=\"archive.zip\"",
          "",
          @zip_b64
        ])

      email = EmlParser.parse(raw)
      attachments = EmlParser.extract_attachments(raw)

      placeholder = EmlParser.placeholder_attachment_text()
      email = Map.put(email, :body, email.body <> "\n" <> placeholder)

      assert {:ok, %{action: :create, incident_id: incident_id, attachments_count: 0}} =
               InboundEmails.ingest_email(building.id, user.id, email, attachments)

      incident = Incidents.get_incident!(incident_id)
      assert incident.files == []

      [comment | _] = incident.comments

      assert String.contains?(comment.body, placeholder),
             "placeholder doit rester si AUCUNE PJ n'a été attachée — sinon le user croit que rien n'est arrivé"
    end

    test "ignore PJ trop grosse (> max_upload_bytes)" do
      building = insert_building!()
      user = insert_user!()

      huge = :binary.copy(<<0>>, LocalStorage.max_upload_bytes() + 1)

      attachments = [
        %{filename: "huge.png", content_type: "image/png", bytes: huge},
        %{filename: "ok.png", content_type: "image/png", bytes: <<137, 80, 78, 71>>}
      ]

      email = %{
        from: "alice@example.com",
        from_name: "Alice",
        to: "bob@example.com",
        cc: nil,
        subject: "Test",
        body: "Body",
        received_at: "27/04/2026"
      }

      assert {:ok, %{attachments_count: 1}} =
               InboundEmails.ingest_email(building.id, user.id, email, attachments)
    end
  end
end
