defmodule ReplicantServer.DocumentsVisibilityTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Repo

  test "list_public_documents returns owned docs whose visibility is public" do
    {:ok, user} = Accounts.upsert_user("rr@robertrich.com", "Robert Rich")

    {:ok, pub} =
      %Document{}
      |> Document.create_changeset(%{
        id: Ecto.UUID.generate(),
        user_id: user.id,
        content: %{"title" => "Owned Public"},
        author_name: "Robert Rich",
        visibility: "public"
      })
      |> Repo.insert()

    ids = Documents.list_public_documents() |> Enum.map(& &1.id)
    assert pub.id in ids
  end

  test "list_public_documents excludes private docs" do
    {:ok, user} = Accounts.get_or_create_user("owner@example.com")

    {:ok, priv} =
      Documents.create_document(user.id, %{
        "id" => Ecto.UUID.generate(),
        "content" => %{"title" => "Private"}
      })

    ids = Documents.list_public_documents() |> Enum.map(& &1.id)
    refute priv.id in ids
  end

  test "create_public_document persists visibility public" do
    {:ok, doc} = Documents.create_public_document(%{"content" => %{"title" => "P"}})
    assert doc.visibility == "public"
  end
end
