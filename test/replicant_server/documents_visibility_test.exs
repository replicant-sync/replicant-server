defmodule ReplicantServer.DocumentsVisibilityTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Collections, Documents, Publications}
  alias ReplicantServer.Collections.Collection
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

  defp user_publication(title) do
    {:ok, user} = Accounts.get_or_create_user("author@example.com")

    {:ok, source} =
      Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"title" => title}})

    {:ok, pub} = Publications.publish(user.id, source.id)
    {user, pub}
  end

  defp public_ids, do: Documents.list_public_documents() |> Enum.map(& &1.id)

  test "public readers include a publication in any public collection, once" do
    {_user, pub} = user_publication("Packed")
    Repo.insert!(%Collection{name: "packs", access: "public"})
    {:ok, _} = Collections.add("packs", pub.id)

    assert pub.id in public_ids()
    assert Documents.get_public_document(pub.id)

    {:ok, _} = Collections.add(Collections.curated(), pub.id)
    assert Enum.count(public_ids(), &(&1 == pub.id)) == 1
    assert Documents.get_public_document(pub.id)
  end

  test "public readers skip a publication in a private collection" do
    {user, pub} = user_publication("Private pack")
    Repo.insert!(%Collection{name: "mine", owner_id: user.id, access: "private"})
    {:ok, _} = Collections.add("mine", pub.id)

    refute pub.id in public_ids()
    refute Documents.get_public_document(pub.id)
  end

  test "a publication leaves the public readers when removed from its collection" do
    {:ok, pub} = Documents.create_public_document(%{content: %{"title" => "Leaving"}})
    {:ok, _} = Collections.remove(Collections.curated(), pub.id)

    refute pub.id in public_ids()
    refute Documents.get_public_document(pub.id)
  end

  test "a deleted public document leaves the public readers" do
    {:ok, pub} = Documents.create_public_document(%{content: %{"title" => "Gone"}})
    {:ok, _} = Documents.delete_public_document(pub.id)

    refute pub.id in public_ids()
    refute Documents.get_public_document(pub.id)
  end

  test "get_public_document returns nil for an id that is not a UUID" do
    assert Documents.get_public_document("not-a-uuid") == nil
  end

  test "list_public_documents searches and sorts public documents" do
    {:ok, a} = Documents.create_public_document(%{content: %{"title" => "Alpha scale"}})
    {:ok, b} = Documents.create_public_document(%{content: %{"title" => "Beta scale"}})
    {:ok, _} = Documents.create_public_document(%{content: %{"title" => "Other"}})

    ids =
      Documents.list_public_documents(search: "scale", sort_by: :title, sort_order: :asc)
      |> Enum.map(& &1.id)

    assert ids == [a.id, b.id]
  end

  describe "publication readers" do
    test "list every live publication, in a public collection or not" do
      {:ok, curated} = Documents.create_public_document(%{content: %{"title" => "Curated"}})
      {user, unlisted} = user_publication("Unlisted")
      {:ok, gone} = Documents.create_public_document(%{content: %{"title" => "Gone"}})
      {:ok, _} = Documents.delete_public_document(gone.id)

      {:ok, own} =
        Documents.create_document(user.id, %{
          id: Ecto.UUID.generate(),
          content: %{"title" => "Own"}
        })

      ids = Documents.list_publications(search: "", sort_by: :title) |> Enum.map(& &1.id)
      assert curated.id in ids
      assert unlisted.id in ids
      refute gone.id in ids
      refute own.id in ids
    end

    test "get a live publication by id, and nothing else" do
      {user, unlisted} = user_publication("Unlisted")

      {:ok, own} =
        Documents.create_document(user.id, %{
          id: Ecto.UUID.generate(),
          content: %{"title" => "Own"}
        })

      assert Documents.get_publication(unlisted.id).id == unlisted.id
      refute Documents.get_publication(own.id)
      refute Documents.get_publication("not-a-uuid")
    end
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
