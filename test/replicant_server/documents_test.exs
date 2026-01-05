defmodule ReplicantServer.DocumentsTest do
  use ReplicantServer.DataCase

  alias ReplicantServer.Documents
  alias ReplicantServer.Accounts

  setup do
    {:ok, user} = Accounts.get_or_create_user("test@example.com")
    %{user: user}
  end

  describe "create_document" do
    test "creates document with event log", %{user: user} do
      doc_id = UUID.uuid4()
      content = %{"title" => "Test", "body" => "Hello"}

      assert {:ok, document} =
               Documents.create_document(user.id, %{id: doc_id, content: content})

      assert document.id == doc_id
      assert document.content == content
      assert document.sync_revision == 1
      assert document.content_hash != nil

      # Verify event was logged
      events = Documents.get_changes_since(user.id, 0)
      assert length(events) == 1
      assert hd(events).event_type == "create"
    end

    test "returns conflict for duplicate ID", %{user: user} do
      doc_id = UUID.uuid4()
      content = %{"title" => "Test"}

      {:ok, _} = Documents.create_document(user.id, %{id: doc_id, content: content})

      assert {:error, :conflict, existing} =
               Documents.create_document(user.id, %{id: doc_id, content: %{"title" => "Other"}})

      assert existing.id == doc_id
    end
  end

  describe "update_document" do
    test "updates with optimistic locking", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original", "count" => 0}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]

      assert {:ok, updated} = Documents.update_document(user.id, doc.id, patch, 1)
      assert updated.content["title"] == "Updated"
      assert updated.sync_revision == 2
    end

    test "fails on version mismatch", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original"}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]

      assert {:error, :version_mismatch, _current} =
               Documents.update_document(user.id, doc.id, patch, 999)
    end

    test "logs forward and reverse patches", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "Original"}
        })

      patch = [%{"op" => "replace", "path" => "/title", "value" => "Updated"}]
      {:ok, _} = Documents.update_document(user.id, doc.id, patch, 1)

      events = Documents.get_changes_since(user.id, 0)
      update_event = Enum.find(events, &(&1.event_type == "update"))

      assert update_event.forward_patch == patch
      assert update_event.reverse_patch != nil
    end
  end

  describe "delete_document" do
    test "soft deletes and logs event", %{user: user} do
      {:ok, doc} =
        Documents.create_document(user.id, %{
          id: UUID.uuid4(),
          content: %{"title" => "To Delete"}
        })

      assert {:ok, deleted} = Documents.delete_document(user.id, doc.id)
      assert deleted.deleted_at != nil

      # Should not appear in list
      assert Documents.list_user_documents(user.id) == []

      # Event logged
      events = Documents.get_changes_since(user.id, 0)
      delete_event = Enum.find(events, &(&1.event_type == "delete"))
      assert delete_event != nil
    end
  end

  describe "content hash" do
    test "computes consistent hash" do
      content = %{"a" => 1, "b" => 2}

      hash1 = Documents.compute_hash(content)
      hash2 = Documents.compute_hash(content)

      assert hash1 == hash2
      assert String.length(hash1) == 64
    end

    test "verifies hash correctly" do
      content = %{"test" => "data"}
      hash = Documents.compute_hash(content)

      assert Documents.verify_hash(content, hash)
      refute Documents.verify_hash(%{"other" => "data"}, hash)
    end
  end
end
