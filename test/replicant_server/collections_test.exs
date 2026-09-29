defmodule ReplicantServer.CollectionsTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Collections, Documents}
  alias ReplicantServer.Collections.{Collection, CollectionMember}
  alias ReplicantServer.Feed.ChangeEvent

  defp events_for(doc_id),
    do: Repo.all(from e in ChangeEvent, where: e.doc_id == ^doc_id, order_by: e.seq)

  defp publication(title) do
    {:ok, pub} = Documents.create_public_document(%{content: %{"title" => title}})
    pub
  end

  test "create_public_document creates a read-only publication in curated" do
    pub = publication("Preset")
    assert pub.read_only
    assert is_nil(pub.user_id)
    assert pub.visibility == "public"
    assert [%{scope: "collection:curated", kind: "upsert", seq: seq}] = events_for(pub.id)
    assert pub.seq == seq
    assert Repo.get_by(CollectionMember, document_id: pub.id)
  end

  test "add is idempotent and remove emits leave" do
    pub = publication("X")
    Repo.insert!(%Collection{name: "packs", access: "public"})

    {:ok, added} = Collections.add("packs", pub.id)
    {:ok, _} = Collections.add("packs", pub.id)

    assert [%{kind: "upsert", seq: add_seq}] =
             Enum.filter(events_for(pub.id), &(&1.scope == "collection:packs"))

    assert added.seq == add_seq

    {:ok, left} = Collections.remove("packs", pub.id)

    assert %{scope: "collection:packs", kind: "leave", seq: leave_seq} =
             List.last(events_for(pub.id))

    assert left.seq == leave_seq
    assert {:error, :not_member} = Collections.remove("packs", pub.id)
  end

  test "add refuses source documents and unknown collections" do
    {:ok, user} = Accounts.get_or_create_user("collections@example.com")
    {:ok, doc} = Documents.create_document(user.id, %{id: Ecto.UUID.generate(), content: %{}})
    assert {:error, :not_publication} = Collections.add("curated", doc.id)
    assert {:error, :not_found} = Collections.add("missing", publication("Y").id)
    assert {:error, :not_found} = Collections.add("curated", Ecto.UUID.generate())
  end

  test "add refuses a deleted publication" do
    pub = publication("Deleted")
    {:ok, _} = Documents.delete_public_document(pub.id)
    assert {:error, :not_found} = Collections.add("curated", pub.id)
  end

  test "replace_content on a publication emits an upsert in each of its collections" do
    pub = publication("v1")
    Repo.insert!(%Collection{name: "packs", access: "public"})
    {:ok, pub} = Collections.add("packs", pub.id)
    {:ok, updated} = Documents.replace_content(pub, %{"title" => "v2"})

    scopes = for e <- events_for(pub.id), e.seq == updated.seq, do: e.scope
    assert Enum.sort(scopes) == ["collection:curated", "collection:packs"]
  end

  test "delete_public_document emits a delete in curated and drops membership" do
    pub = publication("Gone")
    {:ok, deleted} = Documents.delete_public_document(pub.id)

    assert %{kind: "delete", scope: "collection:curated", seq: seq} =
             List.last(events_for(pub.id))

    assert seq == deleted.seq
    refute Repo.get_by(CollectionMember, document_id: pub.id)
    assert {:error, :not_found} = Documents.delete_public_document(pub.id)
  end
end
