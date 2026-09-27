defmodule ReplicantServer.PublicationsTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.{Accounts, Collections, Documents, Publications}
  alias ReplicantServer.Collections.CollectionMember
  alias ReplicantServer.Feed.ChangeEvent

  setup do
    {:ok, user} = Accounts.get_or_create_user("author@example.com")
    {:ok, other} = Accounts.get_or_create_user("reader@example.com")

    {:ok, source} =
      Documents.create_document(user.id, %{
        id: Ecto.UUID.generate(),
        content: %{"title" => "Draft"}
      })

    %{user: user, other: other, source: source}
  end

  defp events_for(doc_id),
    do: Repo.all(from e in ChangeEvent, where: e.doc_id == ^doc_id, order_by: e.seq)

  test "publish copies the source into a read-only publication outside every scope", %{
    user: user,
    source: source
  } do
    assert {:ok, pub} = Publications.publish(user.id, source.id)
    assert pub.id != source.id
    assert pub.read_only
    assert is_nil(pub.user_id)

    assert {pub.author_id, pub.source_doc_id, pub.source_revision} ==
             {user.id, source.id, source.seq}

    assert pub.content == source.content
    assert pub.seq > source.seq
    assert events_for(pub.id) == []
  end

  test "publish refuses other users' documents, publications and deleted sources", %{
    user: user,
    other: other,
    source: source
  } do
    assert {:error, :not_found} = Publications.publish(other.id, source.id)
    {:ok, pub} = Publications.publish(user.id, source.id)
    assert {:error, :not_found} = Publications.publish(user.id, pub.id)
    {:ok, _} = Documents.delete_document(user.id, source.id)
    assert {:error, :not_found} = Publications.publish(user.id, source.id)
  end

  test "publish_update copies the current source and reaches the publication's collections", %{
    user: user,
    source: source
  } do
    {:ok, pub} = Publications.publish(user.id, source.id)
    {:ok, _} = Collections.add("curated", pub.id)
    {:ok, edited} = Documents.replace_content(source, %{"title" => "Final"})

    assert {:ok, updated} = Publications.publish_update(user.id, pub.id)
    assert updated.content == %{"title" => "Final"}
    assert updated.source_revision == edited.seq

    assert %{scope: "collection:curated", kind: "upsert", seq: seq} =
             List.last(events_for(pub.id))

    assert seq == updated.seq
  end

  test "publish_update by a non-author is forbidden; after the source is deleted it is not_found",
       %{user: user, other: other, source: source} do
    {:ok, pub} = Publications.publish(user.id, source.id)
    assert {:error, :forbidden} = Publications.publish_update(other.id, pub.id)
    {:ok, _} = Documents.delete_document(user.id, source.id)
    assert {:error, :not_found} = Publications.publish_update(user.id, pub.id)
  end

  test "unpublish deletes the publication everywhere", %{user: user, other: other, source: source} do
    {:ok, pub} = Publications.publish(user.id, source.id)
    {:ok, _} = Collections.add("curated", pub.id)
    assert {:error, :forbidden} = Publications.unpublish(other.id, pub.id)

    assert {:ok, gone} = Publications.unpublish(user.id, pub.id)
    assert gone.deleted_at

    assert %{kind: "delete", scope: "collection:curated", seq: seq} =
             List.last(events_for(pub.id))

    assert seq == gone.seq
    refute Repo.get_by(CollectionMember, document_id: pub.id)
    assert {:error, :not_found} = Publications.unpublish(user.id, pub.id)
  end
end
