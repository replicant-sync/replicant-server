defmodule ReplicantServer.Sync.ProtocolSnapshotTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Documents, Scopes}
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Documents.Document
  alias ReplicantServer.Sync.Protocol

  setup do
    {:ok, user} = Accounts.get_or_create_user("snapshot@example.com")
    %{user: user, own: Scopes.own(user.id)}
  end

  defp create(user, title) do
    {:ok, doc} =
      Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{"title" => title}})

    doc
  end

  test "the first page fixes snapshot_seq at the head and lists live documents by id", %{
    user: user,
    own: own
  } do
    docs = for t <- ~w(a b c), do: create(user, t)
    {:ok, _} = Documents.delete_document(user.id, create(user, "gone").id)
    {:ok, other} = Accounts.get_or_create_user("snapshot-other@example.com")
    create(other, "theirs")

    assert {:ok, %{docs: page, snapshot_seq: snapshot_seq, next_page_token: nil}} =
             Protocol.snapshot(own, "own", %{})

    assert Enum.map(page, & &1.doc_id) == docs |> Enum.map(& &1.id) |> Enum.sort()
    assert Enum.all?(page, &(&1.seq > 0 and &1.seq <= snapshot_seq))
  end

  test "pages by id; later pages keep snapshot_seq and show newer writes above it", %{
    user: user,
    own: own
  } do
    for t <- ~w(a b c), do: create(user, t)

    assert {:ok, %{docs: [first, second], snapshot_seq: sseq, next_page_token: token}} =
             Protocol.snapshot(own, "own", %{}, 2)

    assert first.doc_id < second.doc_id

    [last] = Repo.all(from d in Document, where: d.user_id == ^user.id and d.id > ^second.doc_id)
    {:ok, edited} = Documents.replace_content(last, %{"title" => "edited"})

    assert {:ok, %{docs: [page2_doc], snapshot_seq: ^sseq, next_page_token: nil}} =
             Protocol.snapshot(own, "own", %{"page_token" => token}, 2)

    assert page2_doc.seq == edited.seq
    assert page2_doc.seq > sseq
  end

  test "an empty scope still returns a snapshot_seq", %{own: own} do
    assert {:ok, %{docs: [], snapshot_seq: sseq, next_page_token: nil}} =
             Protocol.snapshot(own, "own", %{})

    assert is_integer(sseq)
  end

  test "a collection snapshot lists its live publications" do
    curated = Repo.get_by!(Collection, name: "curated")

    pub =
      Repo.insert!(%Document{
        id: Ecto.UUID.generate(),
        content: %{},
        content_hash: "h",
        read_only: true,
        seq: 1
      })

    Repo.insert!(%CollectionMember{collection_id: curated.id, document_id: pub.id, added_seq: 1})

    assert {:ok, %{docs: [%{doc_id: id, read_only: true}]}} =
             Protocol.snapshot("collection:curated", "collection:curated", %{})

    assert id == pub.id
  end

  test "a malformed page_token is validation", %{own: own} do
    assert {:error, %{code: "validation", scope: "own"}} =
             Protocol.snapshot(own, "own", %{"page_token" => "junk"})

    assert {:error, %{code: "validation"}} = Protocol.snapshot(own, "own", %{"page_token" => 5})
  end
end
