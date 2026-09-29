defmodule ReplicantServer.Sync.ProtocolDocumentTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents}
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Sync.Protocol

  setup do
    {:ok, user} = Accounts.get_or_create_user("getdoc@example.com")
    {:ok, other} = Accounts.get_or_create_user("getdoc-other@example.com")
    %{user: user, other: other}
  end

  defp create(user) do
    {:ok, doc} =
      Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"title" => "D"}})

    doc
  end

  defp publication(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Document{id: Ecto.UUID.generate(), content: %{}, content_hash: "h", read_only: true},
        attrs
      )
    )
  end

  defp add_member(collection, doc) do
    Repo.insert!(%CollectionMember{
      collection_id: collection.id,
      document_id: doc.id,
      added_seq: 1
    })
  end

  test "returns the caller's document", %{user: user} do
    doc = create(user)

    assert {:ok, %{doc_id: id, hash: hash, seq: seq, content: %{"title" => "D"}}} =
             Protocol.get_document(user.id, %{"doc_id" => doc.id})

    assert {id, hash, seq} == {doc.id, doc.content_hash, doc.seq}
  end

  test "another user's private document is not_found", %{user: user, other: other} do
    doc = create(user)

    assert {:error, %{code: "not_found", is_fatal: false}} =
             Protocol.get_document(other.id, %{"doc_id" => doc.id})
  end

  test "another user's DELETED private document is not_found, not deleted", %{
    user: user,
    other: other
  } do
    doc = create(user)
    {:ok, _deleted} = Documents.delete_document(user.id, doc.id)

    assert {:error, %{code: "not_found"}} = Protocol.get_document(other.id, %{"doc_id" => doc.id})
  end

  test "a deleted document is 'deleted' with the delete's seq", %{user: user} do
    doc = create(user)
    {:ok, deleted} = Documents.delete_document(user.id, doc.id)

    assert {:error, %{code: "deleted", is_fatal: false, current_seq: seq, doc_id: id}} =
             Protocol.get_document(user.id, %{"doc_id" => doc.id})

    assert {seq, id} == {deleted.seq, doc.id}
  end

  test "an unknown or malformed id is not_found; a missing one is validation", %{user: user} do
    assert {:error, %{code: "not_found"}} =
             Protocol.get_document(user.id, %{"doc_id" => Ecto.UUID.generate()})

    assert {:error, %{code: "not_found"}} = Protocol.get_document(user.id, %{"doc_id" => "junk"})
    assert {:error, %{code: "validation"}} = Protocol.get_document(user.id, %{})
  end

  test "a non-string doc_id or a non-map payload is validation", %{user: user} do
    assert {:error, %{code: "validation"}} = Protocol.get_document(user.id, %{"doc_id" => 123})
    assert {:error, %{code: "validation"}} = Protocol.get_document(user.id, "not a map")
  end

  describe "publications" do
    test "in no collection (live) is not_found", %{other: other} do
      pub = publication()

      assert {:error, %{code: "not_found"}} =
               Protocol.get_document(other.id, %{"doc_id" => pub.id})
    end

    test "in a public collection is ok", %{other: other} do
      public = Repo.get_by!(Collection, name: "curated")
      pub = publication()
      add_member(public, pub)

      assert {:ok, %{doc_id: id, read_only: true}} =
               Protocol.get_document(other.id, %{"doc_id" => pub.id})

      assert id == pub.id
    end

    test "in the caller's own private collection is ok", %{other: other} do
      mine = Repo.insert!(%Collection{name: "other-mine", owner_id: other.id, access: "private"})
      pub = publication()
      add_member(mine, pub)

      assert {:ok, %{doc_id: id}} = Protocol.get_document(other.id, %{"doc_id" => pub.id})
      assert id == pub.id
    end

    test "in another user's private collection is not_found", %{user: user, other: other} do
      theirs =
        Repo.insert!(%Collection{name: "user-private", owner_id: user.id, access: "private"})

      pub = publication()
      add_member(theirs, pub)

      assert {:error, %{code: "not_found"}} =
               Protocol.get_document(other.id, %{"doc_id" => pub.id})
    end

    test "tombstoned publication is 'deleted' to any caller", %{other: other} do
      pub = publication(deleted_at: DateTime.utc_now(), seq: 7)

      assert {:error, %{code: "deleted", current_seq: 7, doc_id: id}} =
               Protocol.get_document(other.id, %{"doc_id" => pub.id})

      assert id == pub.id
    end
  end
end
