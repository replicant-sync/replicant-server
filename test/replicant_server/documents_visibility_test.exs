defmodule ReplicantServer.DocumentsVisibilityTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents, Publications}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Repo

  test "public readers return curated publications" do
    {:ok, pub} = Documents.create_public_document(%{content: %{"title" => "Curated"}})

    assert pub.id in (Documents.list_public_documents() |> Enum.map(& &1.id))
    assert Documents.get_public_document(pub.id)
  end

  test "public readers skip a publication outside any public collection" do
    {:ok, user} = Accounts.get_or_create_user("author@example.com")

    {:ok, source} =
      Documents.create_document(user.id, %{
        id: Ecto.UUID.generate(),
        content: %{"title" => "Draft"}
      })

    {:ok, pub} = Publications.publish(user.id, source.id)

    refute pub.id in (Documents.list_public_documents() |> Enum.map(& &1.id))
    refute Documents.get_public_document(pub.id)
  end

  test "public readers skip an owned document marked public" do
    {:ok, user} = Accounts.upsert_user("rr@robertrich.com", "Robert Rich")

    {:ok, owned} =
      %Document{}
      |> Document.create_changeset(%{
        id: Ecto.UUID.generate(),
        user_id: user.id,
        content: %{"title" => "Owned Public"},
        author_name: "Robert Rich",
        visibility: "public"
      })
      |> Repo.insert()

    refute owned.id in (Documents.list_public_documents() |> Enum.map(& &1.id))
    refute Documents.get_public_document(owned.id)
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
