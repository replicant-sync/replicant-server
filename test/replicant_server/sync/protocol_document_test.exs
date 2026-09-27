defmodule ReplicantServer.Sync.ProtocolDocumentTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents}
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

  test "returns the caller's document", %{user: user} do
    doc = create(user)

    assert {:ok, %{doc_id: id, hash: hash, seq: seq, content: %{"title" => "D"}}} =
             Protocol.get_document(user.id, %{"doc_id" => doc.id})

    assert {id, hash, seq} == {doc.id, doc.content_hash, doc.seq}
  end

  test "a publication is readable by anyone", %{other: other} do
    pub =
      Repo.insert!(%Document{
        id: Ecto.UUID.generate(),
        content: %{},
        content_hash: "h",
        read_only: true,
        seq: 3
      })

    assert {:ok, %{doc_id: id, read_only: true}} =
             Protocol.get_document(other.id, %{"doc_id" => pub.id})

    assert id == pub.id
  end

  test "another user's private document is not_found", %{user: user, other: other} do
    doc = create(user)

    assert {:error, %{code: "not_found", is_fatal: false}} =
             Protocol.get_document(other.id, %{"doc_id" => doc.id})
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
end
