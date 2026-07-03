defmodule ReplicantServer.DocumentsProvenanceTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Repo

  test "copy_document_to_user stamps source provenance and the target's author_name" do
    {:ok, source} = Accounts.upsert_user("rr@robertrich.com", "Robert Rich")
    {:ok, target} = Accounts.upsert_user("sean@sevish.com", "Sevish")

    {:ok, orig} =
      %Document{}
      |> Document.create_changeset(%{
        id: Ecto.UUID.generate(),
        user_id: source.id,
        content: %{"title" => "Original"},
        author_name: "Robert Rich",
        visibility: "private"
      })
      |> Repo.insert()

    {:ok, copy} = Documents.copy_document_to_user(orig.id, source.id, target.id)

    assert copy.author_name == "Sevish"
    assert copy.provenance["copied_from"] == orig.id
    assert copy.provenance["source_author_id"] == source.id
    assert copy.provenance["source_author_name"] == "Robert Rich"
  end

  test "copy attributes a target without a display name by their email local part" do
    {:ok, source} = Accounts.upsert_user("rr@robertrich.com", "Robert Rich")
    {:ok, target} = Accounts.get_or_create_user("sean@sevish.com")

    {:ok, orig} =
      %Document{}
      |> Document.create_changeset(%{
        id: Ecto.UUID.generate(),
        user_id: source.id,
        content: %{"title" => "Original"},
        author_name: "Robert Rich",
        visibility: "private"
      })
      |> Repo.insert()

    {:ok, copy} = Documents.copy_document_to_user(orig.id, source.id, target.id)

    assert copy.author_name == "sean"
  end
end
